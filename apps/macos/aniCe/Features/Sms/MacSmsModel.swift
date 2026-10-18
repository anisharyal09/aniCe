// SPDX-License-Identifier: GPL-3.0-or-later
// Owns SMS capability gating, live assembly, provider paging and reply delivery per peer.
import CryptoKit
import Foundation
import Observation

let smsNotificationPrefix = "anice-sms-"

struct SmsThreadCard: Identifiable, Equatable {
  let key: String
  var threadId: String
  var address: String
  var snippet: String
  var dateMillis: Int64
  var unreadCount: Int64
  /// Created or last refreshed by a live message rather than the provider list, so list refreshes keep it.
  var live = false
  var id: String { key }
}

struct SmsMessageRow: Identifiable, Equatable {
  let messageId: String
  let address: String
  let dateMillis: Int64
  let direction: Int64
  let unread: Bool
  let body: String
  let digest: Data
  var id: String { messageId }
}

struct SmsNotification: Equatable {
  let identifier: String
  let peerKey: String
  let peerName: String
  let address: String
  let threadId: String
  let threadIdentifier: String
  let body: String
  let failure: Bool
}

struct SmsReplyRequest: Equatable {
  let peerKey: String
  let peerName: String
  let address: String
  let threadId: String
  let text: String
}

@MainActor protocol SmsNotifying: AnyObject {
  func post(_ note: SmsNotification) async
}

/** Canonical conversation key: digits with one optional leading `+`, or the trimmed uppercase text for alphanumeric sender IDs. */
func smsNormalizedAddress(_ raw: String) -> String {
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { return trimmed.uppercased() }
  let leading = trimmed.hasPrefix("+")
  let digits = trimmed.filter { $0 >= "0" && $0 <= "9" }
  return !digits.isEmpty && leading ? "+" + digits : digits
}

/** Clamps provider milliseconds into the contract's 0..2^53-1 range. */
func smsClampDate(_ value: Int64) -> Int64 { min(max(value, 0), SmsMessage.maxDate) }

/** Replaces NUL so no transmitted or displayed body can carry it. */
func smsSanitizeText(_ text: String) -> String { text.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}") }

/** Truncates to at most maxBytes UTF-8 bytes on codepoint boundaries. */
func smsTruncate(_ text: String, maxBytes: Int) -> String {
  guard text.utf8.count > maxBytes else { return text }
  var end = text.startIndex
  var index = text.startIndex
  while index < text.endIndex {
    let next = text.index(index, offsetBy: 1)
    if text[text.startIndex..<next].utf8.count > maxBytes { break }
    end = next
    index = next
  }
  return String(text[text.startIndex..<end])
}

/** Byte-wise lexical comparison over the full identifier; numeric ids are never parsed. */
func smsCompareMessageIds(_ a: String, _ b: String) -> Int {
  let left = Array(a.utf8), right = Array(b.utf8)
  for index in 0..<min(left.count, right.count) where left[index] != right[index] {
    return left[index] < right[index] ? -1 : 1
  }
  return left.count == right.count ? 0 : (left.count < right.count ? -1 : 1)
}

@Observable @MainActor final class MacSmsModel: FeatureHandler {
  @Observable final class Conversation {
    var threadId = ""
    var rows: [SmsMessageRow] = []
    var live: [SmsMessageRow] = []
    var nextBeforeMillis: Int64 = 0
    var nextBeforeMessageId = ""
    var more = false
    var requestId = ""
    var transport = ""
    var deadline: TimeInterval = 0
    /// The in-flight request asks for the newest page; its cursor must not disturb older-message paging.
    var refreshing = false
  }

  @Observable final class PeerState {
    var capable = false
    var status = "Waiting for your phone"
    var threads: [SmsThreadCard] = []
    var threadSeen: Set<String> = []
    var pendingThreads = false
    var threadRequest = ""
    var threadTransport = ""
    var threadDeadline: TimeInterval = 0
    var conversations: [String: Conversation] = [:]
    var known: [String: TimeInterval] = [:]
    var contents: [ContentMark] = []
    var assemblies: [String: Assembly] = [:]
    var send: Send?
    /** Counts only, never addresses or bodies: what the live relay delivered and what it suppressed. */
    var liveReceived = 0
    var liveNotified = 0
    var liveSuppressed = 0
  }

  final class Assembly {
    let descriptor: ChannelDescriptor
    let begin: SmsMessage
    let deadline: TimeInterval
    var fragments: [Data] = []
    var committing = false
    init(_ descriptor: ChannelDescriptor, _ begin: SmsMessage, deadline: TimeInterval) {
      self.descriptor = descriptor
      self.begin = begin
      self.deadline = deadline
    }
    var requestId: String { begin.text(1) }
    var messageId: String { begin.text(2) }
    var threadId: String { begin.text(3) }
    var address: String { begin.text(4) }
    var dateMillis: Int64 { begin.number(5) }
    var direction: Int64 { begin.number(6) }
    var unread: Bool { begin.flag(7) }
    var totalBytes: Int { Int(begin.number(8)) }
    var count: Int { Int(begin.number(9)) }
    var digest: Data { begin.bytes(10) }
  }

  struct Send {
    let requestId: String
    let address: String
    let threadId: String
    let text: String
    let descriptor: ChannelDescriptor
    let deadline: TimeInterval
  }

  struct ContentMark {
    let address: String
    let digest: Data
    let dateMillis: Int64
    var expiry: TimeInterval
    /** Whether a notification already announced this content, so a retry or a provider copy never re-announces it. */
    var notified: Bool
  }

  final class Link {
    let channel: any SecuredChannel
    var queue: [SmsMessage] = []
    var sending = false
    var wake = false
    init(_ channel: any SecuredChannel) { self.channel = channel }
  }

  private let notifier: any SmsNotifying
  private let now: () -> TimeInterval
  private let wait: (TimeInterval) async throws -> Void
  private var links: [String: Link] = [:]
  private var peers: [String: PeerState] = [:]
  private var timer: Task<Void, Never>?
  var onLanRequired: () -> Void = {}

  init(notifier: any SmsNotifying,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    wait: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
    self.notifier = notifier
    self.now = now
    self.wait = wait
  }

  private func key(_ peer: DeviceIdentity) -> String { peer.deviceId + ":" + peer.fingerprint }
  private func live(_ descriptor: ChannelDescriptor) -> Bool { links[descriptor.transport]?.channel.descriptor == descriptor }
  private func links(for key: String) -> [Link] {
    ["lan", "ble"].compactMap { links[$0] }.filter { self.key($0.channel.descriptor.peer) == key }
  }
  private func capableLink(_ key: String) -> Link? {
    guard peers[key]?.capable == true else { return nil }
    return links(for: key).first
  }
  private func state(_ key: String) -> PeerState {
    if let existing = peers[key] { return existing }
    let created = PeerState()
    peers[key] = created
    return created
  }
  /// A Bluetooth link carries a smaller thread list so a slow link finishes inside its deadline.
  private func caps(_ transport: String) -> (threads: Int64, messages: Int64) {
    transport == "ble"
      ? (Int64(SmsMessage.bluetoothThreads), Int64(SmsMessage.bluetoothMessages))
      : (Int64(SmsMessage.maximumThreads), Int64(SmsMessage.maximumMessages))
  }
  private func requestDeadline(_ transport: String) -> TimeInterval {
    now() + (transport == "ble" ? 60 : 30)
  }
  private func conversation(_ state: PeerState, _ normalized: String) -> Conversation? {
    guard !normalized.isEmpty else { return nil }
    if let existing = state.conversations[normalized] { return existing }
    let created = Conversation()
    state.conversations[normalized] = created
    return created
  }

  func connected(_ peer: DeviceIdentity) -> Bool { !links(for: key(peer)).isEmpty }
  func supports(_ peer: DeviceIdentity) -> Bool {
    let k = key(peer)
    return peers[k]?.capable == true && !links(for: k).isEmpty
  }
  func threads(_ peer: DeviceIdentity) -> [SmsThreadCard] {
    (peers[key(peer)]?.threads ?? []).sorted {
      $0.dateMillis != $1.dateMillis ? $0.dateMillis > $1.dateMillis : smsCompareMessageIds($0.threadId, $1.threadId) > 0
    }
  }
  func status(_ peer: DeviceIdentity) -> String { peers[key(peer)]?.status ?? "Connect your phone to relay messages" }
  /** Privacy-safe relay state for the panel: the live link and how many live messages arrived, announced or were suppressed as already seen. */
  func diagnostics(_ peer: DeviceIdentity) -> String {
    let k = key(peer)
    guard let state = peers[k] else { return "" }
    var parts: [String] = []
    if let link = links(for: k).first {
      parts.append(link.channel.descriptor.transport == "ble" ? "Bluetooth" : "Local network")
    }
    parts.append("\(state.liveReceived) live received")
    parts.append("\(state.liveNotified) notified")
    parts.append("\(state.liveSuppressed) already seen")
    return parts.joined(separator: " · ")
  }
  func busy(_ peer: DeviceIdentity) -> Bool {
    guard let state = peers[key(peer)] else { return false }
    return state.send != nil || !state.threadRequest.isEmpty || state.conversations.values.contains { !$0.requestId.isEmpty }
  }
  func sending(_ peer: DeviceIdentity) -> Bool { peers[key(peer)]?.send != nil }
  func more(_ peer: DeviceIdentity, address: String) -> Bool {
    peers[key(peer)]?.conversations[smsNormalizedAddress(address)]?.more ?? false
  }
  func destination(_ peer: DeviceIdentity, address: String) -> String {
    let normalized = smsNormalizedAddress(address)
    guard !normalized.isEmpty else { return "" }
    let known = peers[key(peer)]?.conversations[normalized]?.threadId ?? ""
    return known.isEmpty ? "addr:" + normalized : known
  }
  func messages(_ peer: DeviceIdentity, address: String) -> [SmsMessageRow] {
    let normalized = smsNormalizedAddress(address)
    guard !normalized.isEmpty, let conversation = peers[key(peer)]?.conversations[normalized] else { return [] }
    let live = conversation.live.filter { row in
      !conversation.rows.contains { existing in
        existing.digest == row.digest && smsNormalizedAddress(existing.address) == smsNormalizedAddress(row.address)
          && abs(existing.dateMillis - row.dateMillis) <= 5000
      }
    }
    return (conversation.rows + live).sorted {
      $0.dateMillis != $1.dateMillis ? $0.dateMillis > $1.dateMillis : smsCompareMessageIds($0.messageId, $1.messageId) > 0
    }
  }

  func requestThreads(_ peer: DeviceIdentity) {
    let k = key(peer)
    let state = state(k)
    guard state.capable, state.threadRequest.isEmpty, let link = capableLink(k) else {
      state.pendingThreads = state.threadRequest.isEmpty
      if !state.capable { state.status = "Waiting for your phone" }
      else if !state.threadRequest.isEmpty { state.pendingThreads = false }
      return
    }
    state.pendingThreads = false
    issueThreads(state, link, k)
  }

  /// Opens a conversation at its newest page; the stored cursor keeps pointing at older history.
  func refreshMessages(_ peer: DeviceIdentity, address: String) {
    requestPage(peer, address: address, refreshing: true)
  }

  /// Loads the older page the conversation's cursor points at ("Show older messages").
  func requestMessages(_ peer: DeviceIdentity, address: String) {
    requestPage(peer, address: address, refreshing: false)
  }

  private func requestPage(_ peer: DeviceIdentity, address: String, refreshing: Bool) {
    let k = key(peer)
    let state = state(k)
    let normalized = smsNormalizedAddress(address)
    guard let conversation = conversation(state, normalized), conversation.requestId.isEmpty else { return }
    guard !state.conversations.values.contains(where: { !$0.requestId.isEmpty }) else { return }
    guard state.capable, let link = capableLink(k) else {
      state.status = "Connect your phone to read messages"
      return
    }
    let requestId = UUID().uuidString.lowercased()
    conversation.requestId = requestId
    conversation.transport = link.channel.descriptor.transport
    conversation.deadline = requestDeadline(link.channel.descriptor.transport)
    conversation.refreshing = refreshing
    // Live-only threads fall back to the address form; the provider id replaces it once the thread list reports one.
    let threadId = conversation.threadId.isEmpty ? "addr:" + normalized : conversation.threadId
    enqueue(link, SmsMessage(kind: 5, fields: [.text(requestId), .text(threadId),
      .integer(refreshing ? 0 : conversation.nextBeforeMillis), .text(refreshing ? "" : conversation.nextBeforeMessageId),
      .integer(Int64(SmsMessage.defaultPageSize))]))
    state.status = "Loading messages…"
    schedule()
  }

  func send(_ peer: DeviceIdentity, address: String, text: String) {
    submit(key(peer), address: address, text: text, threadId: "")
  }

  private func submit(_ k: String, address: String, text: String, threadId preferred: String) {
    let state = state(k)
    let normalized = smsNormalizedAddress(address)
    let body = smsTruncate(smsSanitizeText(text), maxBytes: Int(SmsMessage.maxBodyBytes))
    guard !normalized.isEmpty else { state.status = "Choose a conversation first"; return }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { state.status = "Write a message first"; return }
    guard state.send == nil else { state.status = "A reply is already in flight"; return }
    guard state.capable, let link = capableLink(k) else {
      state.status = "Connect your phone to send replies"
      return
    }
    let conversation = conversation(state, normalized)
    let requestId = UUID().uuidString.lowercased()
    let data = Data(body.utf8)
    let count = (data.count + 3071) / 3072
    let threadId = !preferred.isEmpty ? preferred
      : (conversation?.threadId.isEmpty == false ? conversation!.threadId : "addr:" + normalized)
    state.send = Send(requestId: requestId, address: address, threadId: threadId, text: body,
      descriptor: link.channel.descriptor, deadline: requestDeadline(link.channel.descriptor.transport))
    enqueue(link, SmsMessage(kind: 11, fields: [.text(requestId), .text(threadId), .text(address),
      .integer(Int64(data.count)), .integer(Int64(count)), .bytes(Data(SHA256.hash(data: data)))]))
    for index in 0..<count {
      let start = index * 3072
      enqueue(link, SmsMessage(kind: 12, fields: [.text(requestId), .integer(Int64(index)),
        .bytes(data.subdata(in: start..<min(start + 3072, data.count)))]))
    }
    enqueue(link, SmsMessage(kind: 13, fields: [.text(requestId)]))
    state.status = "Sending…"
    schedule()
  }

  /** Notification replies fast-fail without a live capable channel instead of queueing forever. */
  func reply(_ request: SmsReplyRequest) async {
    let state = state(request.peerKey)
    guard let link = capableLink(request.peerKey), state.send == nil else {
      state.status = state.send == nil ? "Connect your phone to send replies" : "A reply is already in flight"
      await notifier.post(failureNote(request.peerKey, request.peerName, request.address, request.threadId))
      return
    }
    submit(request.peerKey, address: request.address, text: request.text, threadId: request.threadId)
  }

  func available(_ channel: any SecuredChannel) {
    let descriptor = channel.descriptor
    if live(descriptor) { return }
    links[descriptor.transport] = Link(channel)
    let state = state(key(descriptor.peer))
    announce(links[descriptor.transport]!, descriptor.transport)
    if state.status.isEmpty { state.status = "Waiting for your phone" }
  }

  /// Advertises the relay capability and this link's limits. A peer may announce again, and answering a
  /// capability record recovers a hello the phone never saw without waiting for a new channel generation.
  private func announce(_ link: Link, _ transport: String) {
    let limits = caps(transport)
    enqueue(link, SmsMessage(kind: 1, fields: [.integer(SmsMessage.maxBodyBytes),
      .integer(SmsMessage.maxFragments), .integer(limits.threads), .integer(limits.messages)]))
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard live(descriptor) else { return }
    links[descriptor.transport] = nil
    let k = key(descriptor.peer)
    if links(for: k).isEmpty {
      // Peer data is process-local and never outlives the last authenticated channel.
      peers[k] = nil
    } else if let state = peers[k] {
      // Mid-page loss aborts the page; the next request continues from the last completed cursor.
      if state.threadTransport == descriptor.transport {
        state.threadRequest = ""; state.threadTransport = ""; state.threadDeadline = 0
        state.status = "Connection lost while loading conversations"
      }
      for conversation in state.conversations.values where conversation.transport == descriptor.transport {
        conversation.requestId = ""; conversation.transport = ""; conversation.deadline = 0
        state.status = "Connection lost while loading messages"
      }
      state.assemblies = state.assemblies.filter { $0.value.descriptor != descriptor }
      if let send = state.send, send.descriptor == descriptor {
        state.send = nil; state.status = "Connection lost before the reply was confirmed"
      }
    }
    schedule()
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard live(descriptor), let link = links[descriptor.transport] else { return }
    if link.sending { link.wake = true } else { pump(link) }
  }

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    let message: SmsMessage
    do { guard let decoded = try SmsMessage.decode(bytes) else { return .unrecognized }; message = decoded }
    catch { return .discarded }
    expire()
    guard live(descriptor), let link = links[descriptor.transport], let state = peers[key(descriptor.peer)] else { return .discarded }
    switch message.kind {
    case 1:
      state.capable = true
      if state.status == "Waiting for your phone" { state.status = "Ready" }
      // Answer with our own capability: the phone re-announces while it has not seen ours, so a hello
      // lost on this channel costs a retry rather than parking live messages.
      announce(link, descriptor.transport)
      if state.pendingThreads, state.threadRequest.isEmpty {
        state.pendingThreads = false
        issueThreads(state, link, key(descriptor.peer))
      } else if state.pendingThreads, !state.threadRequest.isEmpty {
        state.pendingThreads = false
      }
      return .handled
    case 3:
      guard state.capable else { return .discarded }
      return recordThread(state, message) ? .handled : .discarded
    case 4:
      guard state.capable else { return .discarded }
      return finishThreads(state, message) ? .handled : .discarded
    case 6:
      guard state.capable else { return .discarded }
      return beginStream(state, message, descriptor) ? .handled : .discarded
    case 7:
      guard state.capable else { return .discarded }
      return fragment(state, message, descriptor) ? .handled : .discarded
    case 8:
      guard state.capable else { return .discarded }
      return await commit(state, message, descriptor)
    case 10:
      guard state.capable else { return .discarded }
      return finishHistory(state, message) ? .handled : .discarded
    case 14:
      guard state.capable else { return .discarded }
      return await finishSend(state, message) ? .handled : .discarded
    default:
      return .unrecognized
    }
  }

  func invalidate() {
    timer?.cancel(); timer = nil
    for descriptor in links.values.map(\.channel.descriptor) { retired(descriptor) }
    peers.removeAll()
    schedule()
  }

  func expire() {
    let time = now()
    var failures: [SmsNotification] = []
    for (k, state) in peers {
      if !state.threadRequest.isEmpty, state.threadDeadline <= time {
        state.threadRequest = ""; state.threadTransport = ""
        state.status = "Your phone did not answer"
      }
      for conversation in state.conversations.values where !conversation.requestId.isEmpty && conversation.deadline <= time {
        conversation.requestId = ""; conversation.transport = ""
        conversation.refreshing = false
        state.status = "Your phone did not answer"
      }
      if let send = state.send, send.deadline <= time {
        state.send = nil
        state.status = "The reply was not confirmed"
        failures.append(failureNote(k, links(for: k).first?.channel.descriptor.peer.deviceName ?? "", send.address, send.threadId))
      }
      state.known = state.known.filter { $0.value > time }
      state.contents.removeAll { $0.expiry <= time }
      state.assemblies = state.assemblies.filter { $0.value.deadline > time }
    }
    for note in failures { Task { await notifier.post(note) } }
    schedule()
  }

  private func failureNote(_ peerKey: String, _ peerName: String, _ address: String, _ threadId: String) -> SmsNotification {
    SmsNotification(identifier: smsNotificationPrefix + "failed-" + UUID().uuidString.lowercased(),
      peerKey: peerKey, peerName: peerName, address: address, threadId: threadId,
      threadIdentifier: smsNormalizedAddress(address), body: "", failure: true)
  }

  private func issueThreads(_ state: PeerState, _ link: Link, _ k: String) {
    let requestId = UUID().uuidString.lowercased()
    state.threadRequest = requestId
    state.threadTransport = link.channel.descriptor.transport
    state.threadDeadline = requestDeadline(link.channel.descriptor.transport)
    state.threadSeen = []
    state.status = "Loading conversations…"
    enqueue(link, SmsMessage(kind: 2, fields: [.text(requestId)]))
    schedule()
  }

  private func recordThread(_ state: PeerState, _ m: SmsMessage) -> Bool {
    // Records are only accepted while their request is the active one; late records change nothing.
    guard !state.threadRequest.isEmpty, m.text(0) == state.threadRequest else { return false }
    let normalized = smsNormalizedAddress(m.text(2))
    guard !normalized.isEmpty else { return false }
    let threadId = m.text(1)
    var card = SmsThreadCard(key: normalized, threadId: threadId, address: m.text(2),
      snippet: smsTruncate(smsSanitizeText(m.text(3)), maxBytes: 160),
      dateMillis: smsClampDate(m.number(4)), unreadCount: min(m.number(5), SmsMessage.maxDate))
    card.live = false
    state.threadSeen.insert(normalized)
    if let index = state.threads.firstIndex(where: { $0.key == normalized }) {
      state.threads[index] = card
    } else {
      state.threads.append(card)
    }
    guard let conversation = conversation(state, normalized) else { return true }
    if conversation.threadId.isEmpty {
      conversation.threadId = threadId
    } else if conversation.threadId != threadId, conversation.requestId.isEmpty {
      // A provider identity replaces the address fallback; paging restarts from the newest row.
      conversation.threadId = threadId
      conversation.nextBeforeMillis = 0
      conversation.nextBeforeMessageId = ""
      conversation.more = false
    }
    return true
  }

  private func finishThreads(_ state: PeerState, _ m: SmsMessage) -> Bool {
    guard !state.threadRequest.isEmpty, m.text(0) == state.threadRequest else { return false }
    state.threadRequest = ""; state.threadTransport = ""; state.threadDeadline = 0
    switch m.number(1) {
    case 0:
      // A completed list is a snapshot: provider conversations it no longer reports disappear, while
      // cards a live message created stay until a later snapshot adopts or replaces them.
      let seen = state.threadSeen
      state.threads.removeAll { !$0.live && !seen.contains($0.key) }
      state.status = state.threads.isEmpty ? "No conversations on your phone" : "\(state.threads.count) conversations"
    case 1: state.status = "Allow SMS access on your phone to read conversations"
    default: state.status = "Conversations are unavailable"
    }
    state.threadSeen = []
    schedule()
    return true
  }

  private func beginStream(_ state: PeerState, _ m: SmsMessage, _ descriptor: ChannelDescriptor) -> Bool {
    let streamId = m.text(0)
    let requestId = m.text(1)
    if !requestId.isEmpty, !state.conversations.values.contains(where: { $0.requestId == requestId }) { return false }
    if let existing = state.assemblies[streamId] {
      if existing.descriptor == descriptor, existing.begin == m { return true }
      state.assemblies[streamId] = nil
      // A conflicting duplicate on one channel is invalid; a retry on the other channel restarts the stream.
      if existing.descriptor == descriptor {
        if existing.requestId.isEmpty { ack(descriptor, streamId, 6) }
        return true
      }
    }
    state.assemblies[streamId] = Assembly(descriptor, m, deadline: now() + 30)
    schedule()
    return true
  }

  private func fragment(_ state: PeerState, _ m: SmsMessage, _ descriptor: ChannelDescriptor) -> Bool {
    let streamId = m.text(0)
    guard let assembly = state.assemblies[streamId], assembly.descriptor == descriptor, !assembly.committing else { return false }
    let index = Int(m.number(1)), data = m.bytes(2)
    let expected = index == assembly.count - 1 ? assembly.totalBytes - index * 3072 : 3072
    guard index < assembly.count, data.count == expected, index <= assembly.fragments.count,
      index == assembly.fragments.count || assembly.fragments[index] == data else {
      state.assemblies[streamId] = nil
      if assembly.requestId.isEmpty { ack(descriptor, streamId, 6) }
      return true
    }
    if index == assembly.fragments.count { assembly.fragments.append(data) }
    return true
  }

  private func commit(_ state: PeerState, _ m: SmsMessage, _ descriptor: ChannelDescriptor) async -> DataHandling {
    let streamId = m.text(0)
    guard let assembly = state.assemblies[streamId], assembly.descriptor == descriptor else { return .discarded }
    guard assembly.fragments.count == assembly.count, !assembly.committing else {
      state.assemblies[streamId] = nil
      if assembly.requestId.isEmpty { ack(descriptor, streamId, 6) }
      return .handled
    }
    assembly.committing = true
    let fragments = assembly.fragments, digest = assembly.digest
    let text = await Task.detached { () -> String? in
      let data = fragments.reduce(into: Data()) { $0.append($1) }
      guard Data(SHA256.hash(data: data)) == digest, let body = String(data: data, encoding: .utf8),
        !body.contains("\0") else { return nil }
      return body
    }.value
    state.assemblies[streamId] = nil
    guard let text else {
      if assembly.requestId.isEmpty { ack(descriptor, streamId, 6) }
      return .handled
    }
    if assembly.requestId.isEmpty {
      ack(descriptor, streamId, 0)
      await admitLive(state, assembly, body: text, digest: digest, peer: descriptor.peer)
    } else {
      admitProvider(state, assembly, body: text, digest: digest)
    }
    return .handled
  }

  private func admitLive(_ state: PeerState, _ assembly: Assembly, body: String, digest: Data, peer: DeviceIdentity) async {
    let time = now()
    let normalized = smsNormalizedAddress(assembly.address)
    let mark = state.contents.firstIndex {
      $0.address == normalized && $0.digest == digest && abs($0.dateMillis - assembly.dateMillis) <= 5000 && $0.expiry > time
    }
    // A provider copy of the same message owns its row, but only a delivered notification suppresses the next one:
    // an event that lands after the panel already fetched the provider copy still announces the message.
    let announced = mark.map { state.contents[$0].notified } ?? false
    let duplicate = state.known[assembly.messageId] != nil || mark != nil
    state.known[assembly.messageId] = time + 600
    if let index = mark {
      state.contents[index].expiry = time + 600
      state.contents[index].notified = true
    } else {
      state.contents.append(ContentMark(address: normalized, digest: digest, dateMillis: assembly.dateMillis,
        expiry: time + 600, notified: true))
    }
    state.liveReceived += 1
    if duplicate { state.liveSuppressed += 1 }
    guard let conversation = conversation(state, normalized) else { return }
    if !duplicate {
      let row = SmsMessageRow(messageId: assembly.messageId, address: assembly.address, dateMillis: assembly.dateMillis,
        direction: assembly.direction, unread: assembly.unread, body: body, digest: digest)
      conversation.live.append(row)
      upsertCard(state, address: assembly.address, snippet: body, dateMillis: assembly.dateMillis, unread: assembly.unread ? 1 : 0)
    }
    if announced { return }
    state.status = "Message received"
    state.liveNotified += 1
    await notifier.post(SmsNotification(identifier: smsNotificationPrefix + assembly.messageId, peerKey: key(peer),
      peerName: peer.deviceName, address: assembly.address, threadId: conversation.threadId,
      threadIdentifier: normalized, body: body, failure: false))
    schedule()
  }

  private func admitProvider(_ state: PeerState, _ assembly: Assembly, body: String, digest: Data) {
    guard let (normalized, conversation) = state.conversations.first(where: { $0.value.requestId == assembly.requestId }) else { return }
    let time = now()
    state.known[assembly.messageId] = time + 600
    // The provider copy never notifies; an existing mark keeps the announced state its live copy may have set.
    if let index = state.contents.firstIndex(where: {
      $0.address == normalized && $0.digest == digest && abs($0.dateMillis - assembly.dateMillis) <= 5000
    }) {
      state.contents[index].expiry = time + 600
    } else {
      state.contents.append(ContentMark(address: normalized, digest: digest, dateMillis: assembly.dateMillis,
        expiry: time + 600, notified: false))
    }
    // The provider record wins: its live copy is replaced and an existing posted notification is untouched.
    conversation.live.removeAll {
      $0.digest == digest && abs($0.dateMillis - assembly.dateMillis) <= 5000 && smsNormalizedAddress($0.address) == normalized
    }
    guard !conversation.rows.contains(where: { $0.messageId == assembly.messageId }) else { return }
    conversation.rows.append(SmsMessageRow(messageId: assembly.messageId, address: assembly.address, dateMillis: assembly.dateMillis,
      direction: assembly.direction, unread: assembly.unread, body: body, digest: digest))
    if let index = state.threads.firstIndex(where: { $0.key == normalized }) {
      var card = state.threads[index]
      card.threadId = assembly.threadId
      state.threads[index] = card
    }
  }

  private func finishHistory(_ state: PeerState, _ m: SmsMessage) -> Bool {
    guard let (_, conversation) = state.conversations.first(where: { $0.value.requestId == m.text(0) }) else { return false }
    let refreshing = conversation.refreshing
    conversation.requestId = ""; conversation.transport = ""; conversation.deadline = 0; conversation.refreshing = false
    guard m.number(1) == 0 else {
      // A failed newest-page refresh leaves older paging state untouched; a failed older page stops offering more.
      if !refreshing { conversation.more = false }
      state.status = m.number(1) == 1 ? "Allow SMS access on your phone to read messages" : "Messages are unavailable"
      schedule()
      return true
    }
    // Cursors advance only on success; a zero pair is the terminal page.
    let terminal = m.number(2) == 0 && m.text(3).isEmpty
    let unpaged = conversation.nextBeforeMillis == 0 && conversation.nextBeforeMessageId.isEmpty
    if terminal {
      if !refreshing || unpaged { conversation.more = false }
    } else if !refreshing || unpaged {
      // A newest-page refresh never rewinds an older-message cursor the user already paged to.
      conversation.nextBeforeMillis = m.number(2)
      conversation.nextBeforeMessageId = m.text(3)
      conversation.more = true
    }
    state.status = conversation.more ? "Older messages available" : "All messages loaded"
    schedule()
    return true
  }

  private func finishSend(_ state: PeerState, _ m: SmsMessage) async -> Bool {
    guard let send = state.send, send.requestId == m.text(0) else { return false }
    state.send = nil
    let code = m.number(1)
    if code == 0 {
      let providerId = m.text(2)
      let millis = smsClampDate(m.number(3))
      let stamp = millis == 0 ? Int64(Date().timeIntervalSince1970 * 1000) : millis
      let messageId = providerId.isEmpty ? "echo:" + UUID().uuidString.lowercased() : providerId
      let conversation = conversation(state, smsNormalizedAddress(send.address))
      conversation?.live.append(SmsMessageRow(messageId: messageId, address: send.address,
        dateMillis: stamp, direction: 1, unread: false,
        body: send.text, digest: Data(SHA256.hash(data: Data(send.text.utf8)))))
      upsertCard(state, address: send.address, snippet: send.text, dateMillis: stamp, unread: 0)
      state.status = "Sent"
    } else {
      state.status = code == 1 ? "Allow SMS on your phone to send replies" : code == 5 ? "The reply failed to send" : "The reply was rejected"
      if code == 1 || code == 5 {
        await notifier.post(failureNote(key(send.descriptor.peer), send.descriptor.peer.deviceName, send.address, send.threadId))
      }
    }
    schedule()
    return true
  }

  private func upsertCard(_ state: PeerState, address: String, snippet: String, dateMillis: Int64, unread: Int64) {
    let normalized = smsNormalizedAddress(address)
    guard !normalized.isEmpty else { return }
    let text = smsTruncate(smsSanitizeText(snippet), maxBytes: 160)
    if let index = state.threads.firstIndex(where: { $0.key == normalized }) {
      var card = state.threads[index]
      if dateMillis >= card.dateMillis { card.snippet = text; card.dateMillis = dateMillis }
      card.address = address.isEmpty ? card.address : address
      card.unreadCount += unread
      card.live = true
      state.threads[index] = card
    } else {
      state.threads.append(SmsThreadCard(key: normalized, threadId: "", address: address, snippet: text,
        dateMillis: dateMillis, unreadCount: unread, live: true))
    }
  }

  private func ack(_ descriptor: ChannelDescriptor, _ streamId: String, _ code: Int64) {
    guard live(descriptor), let link = links[descriptor.transport] else { return }
    enqueue(link, SmsMessage(kind: 9, fields: [.text(streamId), .integer(code)]))
  }

  private func schedule() {
    timer?.cancel(); timer = nil
    var deadlines: [TimeInterval] = []
    for state in peers.values {
      if !state.threadRequest.isEmpty { deadlines.append(state.threadDeadline) }
      deadlines.append(contentsOf: state.conversations.values.filter { !$0.requestId.isEmpty }.map(\.deadline))
      if let send = state.send { deadlines.append(send.deadline) }
      deadlines.append(contentsOf: state.known.values)
      deadlines.append(contentsOf: state.contents.map(\.expiry))
      deadlines.append(contentsOf: state.assemblies.values.map(\.deadline))
    }
    guard let next = deadlines.min() else { return }
    let delay = max(0.001, next - now()), wait = self.wait
    timer = Task { [weak self] in
      do { try await wait(delay) } catch { return }
      self?.expire()
    }
  }

  private func enqueue(_ link: Link, _ message: SmsMessage) {
    guard live(link.channel.descriptor), link.queue.count < 32 else { return }
    link.queue.append(message)
    pump(link)
  }

  private func pump(_ link: Link) {
    guard !link.sending else { return }
    link.sending = true
    Task { [weak self] in
      guard let self else { link.sending = false; return }
      defer { link.sending = false; self.schedule() }
      repeat {
        link.wake = false
        while self.live(link.channel.descriptor), let first = link.queue.first {
          do { try await link.channel.sendData(first.encode()) }
          catch is SessionBackpressure { break }
          catch { link.queue.removeAll(); return }
          if link.queue.first == first { link.queue.removeFirst() }
        }
      } while link.wake && self.live(link.channel.descriptor)
    }
  }
}
