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
  /** The receiving subscription as the phone reported it; 0 means unknown (MMS or no readable provider id). */
  var subscriptionId: Int64 = 0
  var id: String { messageId }
}

/** One active SMS subscription as the phone reported it; numbers are never transmitted. */
struct SmsSimEntry: Identifiable, Equatable {
  let subscriptionId: Int64
  let slotIndex: Int64
  let label: String
  let isDefault: Bool
  var id: Int64 { subscriptionId }
}

/** A search hit: enough context to show a result row without touching the conversation store. */
struct SmsSearchRow: Identifiable, Equatable {
  let messageId: String
  let threadId: String
  let address: String
  let dateMillis: Int64
  let direction: Int64
  let body: String
  var subscriptionId: Int64 = 0
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

enum SmsPostOutcome: Sendable { case submitted, duplicate, denied, alertsDisabled, failed, cancelled, muted }
enum SmsNotificationAccess: Sendable {
  case authorized, denied, alertsDisabled, notDetermined
}
@MainActor protocol SmsNotifying: AnyObject {
  var status: String { get }
  func refreshSettings() async
  func clear(peerKey: String)
  func post(_ note: SmsNotification) async -> SmsPostOutcome
}
extension SmsNotifying {
  var status: String { "" }
  func refreshSettings() async {}
  func clear(peerKey: String) {}
}

/** Two subscriptions can carry the same display name; the slot disambiguates them for display. */
func smsSimLabel(_ entry: SmsSimEntry, of entries: [SmsSimEntry]) -> String {
  if !entry.label.isEmpty && entries.filter({ $0.label == entry.label }).count > 1 {
    return "\(entry.label) (SIM \(entry.slotIndex + 1))"
  }
  return entry.label.isEmpty ? "SIM \(entry.slotIndex + 1)" : entry.label
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

  /** One peer-scoped search session: the active page request, its buffer and the next-page cursor. Nothing here is persisted. */
  @Observable final class Search {
    var requestId = ""
    var transport = ""
    var deadline: TimeInterval = 0
    var query = ""
    var results: [SmsSearchRow] = []
    var nextBeforeMillis: Int64 = 0
    var nextBeforeMessageId = ""
    var more = false
    /// Completed pages, capped with the row count so a result list stays bounded.
    var pages = 0
    var note = ""
  }

  @Observable final class PeerState {
    var capable = false
    var status = "Waiting for your phone"
    var threads: [SmsThreadCard] = []
    var threadCards: [String: SmsThreadCard] = [:]
    var pendingThreads = false
    var threadRequest = ""
    var threadTransport = ""
    var threadDeadline: TimeInterval = 0
    /** Thread-list cursor: the page after this one exists while [threadMore] stays true. */
    var threadMore = false
    var threadNextMillis: Int64 = 0
    var threadNextThreadId = ""
    /** The in-flight request is the newest page, a snapshot that drops provider cards it no longer reports. */
    var threadFirstPage = true
    var conversations: [String: Conversation] = [:]
    var known: [String: TimeInterval] = [:]
    var contents: [ContentMark] = []
    var assemblies: [String: Assembly] = [:]
    var send: Send?
    var simEntries: [SmsSimEntry] = []
    var simChoice: Int64 = 0
    var simRequest = ""
    var simTransport = ""
    var simDeadline: TimeInterval = 0
    var search: Search?
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
    var subscriptionId: Int64 { begin.number(11) }
  }

  struct Send {
    let requestId: String
    let address: String
    let threadId: String
    let text: String
    /** The subscription the reply was submitted on; 0 means the phone default and stays 0 on the echo. */
    let subscriptionId: Int64
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
    var liveMessageId: String? = nil
    let direction: Int64
    /** 0 means the origin is unknown; a known origin must match before two copies collapse into one. */
    let subscriptionId: Int64
  }

  final class Queued {
    let message: SmsMessage
    let owner: String
    let deadline: TimeInterval
    init(_ message: SmsMessage, owner: String, deadline: TimeInterval) {
      self.message = message; self.owner = owner; self.deadline = deadline
    }
  }
  final class Link {
    let channel: any SecuredChannel
    var queue: [Queued] = []
    var sending = false
    var wake = false
    var capable = false
    var maximumThreads = 50
    var maximumMessages = 50
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
    return links(for: key).first { $0.capable }
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
    return capableLink(k) != nil
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
    if let link = capableLink(k) {
      parts.append(link.channel.descriptor.transport == "ble" ? "Bluetooth" : "Local network")
    }
    parts.append("\(state.liveReceived) live received")
    parts.append("\(state.liveNotified) Submitted to macOS")
    parts.append("\(state.liveSuppressed) already seen")
    return parts.joined(separator: " · ")
  }
  func busy(_ peer: DeviceIdentity) -> Bool {
    guard let state = peers[key(peer)] else { return false }
    return state.send != nil || !state.threadRequest.isEmpty || state.conversations.values.contains { !$0.requestId.isEmpty }
  }
  var notificationStatus: String { notifier.status }
  func refreshNotificationSettings() async { await notifier.refreshSettings() }
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
    var unmatched = conversation.rows
    let live = conversation.live.filter { row in
      if let index = unmatched.firstIndex(where: { existing in
        existing.direction == row.direction && existing.digest == row.digest &&
          smsNormalizedAddress(existing.address) == smsNormalizedAddress(row.address) && abs(existing.dateMillis - row.dateMillis) <= 5000 &&
          (existing.subscriptionId == 0 || row.subscriptionId == 0 || existing.subscriptionId == row.subscriptionId)
      }) { unmatched.remove(at: index); return false }
      return true
    }
    return (conversation.rows + live).sorted {
      $0.dateMillis != $1.dateMillis ? $0.dateMillis > $1.dateMillis : smsCompareMessageIds($0.messageId, $1.messageId) > 0
    }
  }

  /** Whether the thread list has another page; the view asks for it when its last card appears. */
  func threadMore(_ peer: DeviceIdentity) -> Bool { peers[key(peer)]?.threadMore ?? false }

  /** The display label for a row's subscription, falling back to the raw id when the listing is unavailable. */
  func simName(_ peer: DeviceIdentity, subscriptionId: Int64) -> String {
    if subscriptionId == 0 { return "Phone default" }
    let entries = peers[key(peer)]?.simEntries ?? []
    guard let entry = entries.first(where: { $0.subscriptionId == subscriptionId }) else { return "SIM \(subscriptionId)" }
    return smsSimLabel(entry, of: entries)
  }

  /** Whether a conversation mixes two or more known subscriptions, which is when per-row SIM labels earn their space. */
  func mixedSubscriptions(_ peer: DeviceIdentity, address: String) -> Bool {
    let normalized = smsNormalizedAddress(address)
    guard !normalized.isEmpty, let conversation = peers[key(peer)]?.conversations[normalized] else { return false }
    let known = Set((conversation.rows + conversation.live).map(\.subscriptionId).filter { $0 != 0 })
    return known.count >= 2
  }

  /** The picker exists only when the phone reports at least two subscriptions. */
  func sims(_ peer: DeviceIdentity) -> [SmsSimEntry] {
    let entries = peers[key(peer)]?.simEntries ?? []
    return entries.count >= 2 ? entries : []
  }
  func simChoice(_ peer: DeviceIdentity) -> Int64 { peers[key(peer)]?.simChoice ?? 0 }

  func searchResults(_ peer: DeviceIdentity) -> [SmsSearchRow] { peers[key(peer)]?.search?.results ?? [] }
  func searchStatus(_ peer: DeviceIdentity) -> String { peers[key(peer)]?.search?.note ?? "" }
  func searching(_ peer: DeviceIdentity) -> Bool { !(peers[key(peer)]?.search?.requestId.isEmpty ?? true) }
  /** More pages exist and the buffer is still under the four-page/200-row cap. */
  func moreResults(_ peer: DeviceIdentity) -> Bool {
    guard let search = peers[key(peer)]?.search else { return false }
    return search.requestId.isEmpty && search.more && !searchCapped(search)
  }
  /** The cursor points at more rows the cap refuses to load: the user has to narrow the query. */
  func refineSearch(_ peer: DeviceIdentity) -> Bool {
    guard let search = peers[key(peer)]?.search else { return false }
    return search.requestId.isEmpty && search.more && searchCapped(search)
  }
  private func searchCapped(_ search: Search) -> Bool { search.pages >= 4 || search.results.count >= 200 }

  func requestThreads(_ peer: DeviceIdentity) {
    onLanRequired()
    let k = key(peer)
    let state = state(k)
    guard state.capable, state.threadRequest.isEmpty, let link = capableLink(k) else {
      state.pendingThreads = state.threadRequest.isEmpty
      if !state.capable { state.status = "Waiting for your phone" }
      else if !state.threadRequest.isEmpty { state.pendingThreads = false }
      return
    }
    state.pendingThreads = false
    issueThreads(state, link, k, firstPage: true)
  }

  /** Loads the next thread page the previous [threadMore] cursor points at. */
  func requestMoreThreads(_ peer: DeviceIdentity) {
    onLanRequired()
    let k = key(peer)
    let state = state(k)
    guard state.capable, state.threadMore, state.threadRequest.isEmpty, let link = capableLink(k) else { return }
    issueThreads(state, link, k, firstPage: false)
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
    onLanRequired()
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
      .integer(Int64(min(SmsMessage.defaultPageSize, link.maximumMessages)))]))
    state.status = "Loading messages…"
    schedule()
  }

  /** Asks the phone for its active SMS subscriptions; the listing stays silent unless it offers a second choice. */
  func requestSims(_ peer: DeviceIdentity) {
    let k = key(peer)
    let state = state(k)
    guard state.simRequest.isEmpty, state.capable, let link = capableLink(k) else { return }
    onLanRequired()
    let requestId = UUID().uuidString.lowercased()
    state.simRequest = requestId
    state.simTransport = link.channel.descriptor.transport
    state.simDeadline = now() + 10
    enqueue(link, SmsMessage(kind: 15, fields: [.text(requestId)]))
    schedule()
  }

  /** The choice is per peer and process-local; a listing that no longer offers it falls back to the phone default. */
  func chooseSim(_ peer: DeviceIdentity, _ subscriptionId: Int64) {
    let state = state(key(peer))
    guard subscriptionId == 0 || sims(peer).contains(where: { $0.subscriptionId == subscriptionId }) else { return }
    state.simChoice = subscriptionId
  }

  /** A fresh query cancels the previous page and replaces the buffer; blank clears, under two bytes only warns. */
  func search(_ peer: DeviceIdentity, query: String) {
    let k = key(peer)
    let state = state(k)
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { clearSearch(peer); return }
    cancelSearch(state)
    guard trimmed.utf8.count >= 2 else {
      let search = Search()
      search.note = "Search needs at least 2 characters"
      state.search = search
      return
    }
    guard state.capable, let link = capableLink(k) else {
      let search = Search()
      search.query = trimmed
      search.note = "Connect your phone to search messages"
      state.search = search
      return
    }
    onLanRequired()
    let search = Search()
    search.query = smsTruncate(trimmed, maxBytes: 64)
    search.transport = link.channel.descriptor.transport
    search.deadline = requestDeadline(search.transport)
    search.requestId = UUID().uuidString.lowercased()
    search.note = "Searching…"
    state.search = search
    issueSearch(link, search, millis: 0, messageId: "")
  }

  /** Leaving the results drops the buffer and any page in flight. */
  func clearSearch(_ peer: DeviceIdentity) {
    guard let state = peers[key(peer)] else { return }
    cancelSearch(state)
    schedule()
  }

  func searchMore(_ peer: DeviceIdentity) {
    onLanRequired()
    let k = key(peer)
    let state = state(k)
    guard let search = state.search, search.requestId.isEmpty, search.more, !searchCapped(search) else { return }
    guard state.capable, let link = capableLink(k) else {
      search.note = "Connect your phone to load more results"
      return
    }
    search.requestId = UUID().uuidString.lowercased()
    search.transport = link.channel.descriptor.transport
    search.deadline = requestDeadline(search.transport)
    search.note = "Searching…"
    issueSearch(link, search, millis: search.nextBeforeMillis, messageId: search.nextBeforeMessageId)
  }

  private func issueSearch(_ link: Link, _ search: Search, millis: Int64, messageId: String) {
    enqueue(link, SmsMessage(kind: 17, fields: [.text(search.requestId), .text(search.query),
      .integer(millis), .text(messageId), .integer(Int64(min(SmsMessage.defaultPageSize, link.maximumMessages)))]))
    schedule()
  }

  private func cancelSearch(_ state: PeerState) {
    guard let search = state.search else { return }
    if !search.requestId.isEmpty {
      cancelQueued(search.requestId)
      state.assemblies = state.assemblies.filter { $0.value.requestId != search.requestId }
    }
    state.search = nil
  }

  func send(_ peer: DeviceIdentity, address: String, text: String) {
    submit(key(peer), address: address, text: text, threadId: "", subscriptionId: peers[key(peer)]?.simChoice ?? 0)
  }

  private func submit(_ k: String, address: String, text: String, threadId preferred: String, subscriptionId: Int64 = 0) {
    onLanRequired()
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
    guard link.queue.count + count + 2 <= 32 else { state.status = "SMS channel is busy"; return }
    let threadId = !preferred.isEmpty ? preferred
      : (conversation?.threadId.isEmpty == false ? conversation!.threadId : "addr:" + normalized)
    // An explicit choice is kept for the echo; 0 resolves to the known default so a mixed thread still labels the send.
    let resolved = subscriptionId != 0 ? subscriptionId : (state.simEntries.first(where: \.isDefault)?.subscriptionId ?? 0)
    state.send = Send(requestId: requestId, address: address, threadId: threadId, text: body, subscriptionId: resolved,
      descriptor: link.channel.descriptor, deadline: requestDeadline(link.channel.descriptor.transport))
    enqueue(link, SmsMessage(kind: 11, fields: [.text(requestId), .text(threadId), .text(address),
      .integer(Int64(data.count)), .integer(Int64(count)), .bytes(Data(SHA256.hash(data: data))),
      .integer(subscriptionId)]))
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
    submit(request.peerKey, address: request.address, text: request.text, threadId: request.threadId, subscriptionId: 0)
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
    links[descriptor.transport]?.queue.removeAll()
    links[descriptor.transport] = nil
    let k = key(descriptor.peer)
    if links(for: k).isEmpty {
      // Peer data is process-local and never outlives the last authenticated channel.
      notifier.clear(peerKey: k)
      peers[k] = nil
    } else if let state = peers[k] {
      // Mid-page loss aborts the page; the next request continues from the last completed cursor.
      if state.threadTransport == descriptor.transport {
        state.threadRequest = ""; state.threadTransport = ""; state.threadDeadline = 0
        state.threadFirstPage = true
        state.status = "Connection lost while loading conversations"
      }
      for conversation in state.conversations.values where conversation.transport == descriptor.transport {
        conversation.requestId = ""; conversation.transport = ""; conversation.deadline = 0
        state.status = "Connection lost while loading messages"
      }
      if !state.simRequest.isEmpty, state.simTransport == descriptor.transport {
        state.simRequest = ""; state.simTransport = ""; state.simDeadline = 0
      }
      if let search = state.search, search.transport == descriptor.transport {
        search.requestId = ""; search.transport = ""; search.deadline = 0
        search.note = "Connection lost while searching"
      }
      state.assemblies = state.assemblies.filter { $0.value.descriptor != descriptor }
      if let send = state.send, send.descriptor == descriptor {
        state.send = nil; state.status = "Not confirmed; it may have been sent"
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
      link.capable = true
      link.maximumThreads = Int(message.number(2))
      link.maximumMessages = Int(message.number(3))
      state.capable = true
      if state.status == "Waiting for your phone" { state.status = "Ready" }
      // Answer with our own capability: the phone re-announces while it has not seen ours, so a hello
      // lost on this channel costs a retry rather than parking live messages.
      announce(link, descriptor.transport)
      if state.pendingThreads, state.threadRequest.isEmpty {
        state.pendingThreads = false
        issueThreads(state, link, key(descriptor.peer), firstPage: true)
      } else if state.pendingThreads, !state.threadRequest.isEmpty {
        state.pendingThreads = false
      }
      return .handled
    case 3:
      guard state.threadTransport == descriptor.transport else { return .discarded }
      guard link.capable else { return .discarded }
      return recordThread(state, message) ? .handled : .discarded
    case 4:
      guard state.threadTransport == descriptor.transport else { return .discarded }
      guard link.capable else { return .discarded }
      return finishThreads(state, message) ? .handled : .discarded
    case 6:
      guard link.capable else { return .discarded }
      return beginStream(state, message, descriptor) ? .handled : .discarded
    case 7:
      guard link.capable else { return .discarded }
      return fragment(state, message, descriptor) ? .handled : .discarded
    case 8:
      guard link.capable else { return .discarded }
      return await commit(state, message, descriptor)
    case 10:
      guard state.conversations.values.contains(where: { $0.requestId == message.text(0) && $0.transport == descriptor.transport }) else { return .discarded }
      guard link.capable else { return .discarded }
      return finishHistory(state, message) ? .handled : .discarded
    case 14:
      guard state.send?.descriptor == descriptor else { return .discarded }
      guard link.capable else { return .discarded }
      return await finishSend(state, message) ? .handled : .discarded
    case 16:
      guard state.simTransport == descriptor.transport else { return .discarded }
      guard link.capable else { return .discarded }
      return finishSims(state, message) ? .handled : .discarded
    case 18:
      guard state.search?.transport == descriptor.transport else { return .discarded }
      guard link.capable else { return .discarded }
      return finishSearch(state, message) ? .handled : .discarded
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
        cancelQueued(state.threadRequest)
        state.threadCards = [:]
        state.threadFirstPage = true
        state.threadRequest = ""; state.threadTransport = ""
        state.status = "Your phone did not answer"
      }
      for conversation in state.conversations.values where !conversation.requestId.isEmpty && conversation.deadline <= time {
        conversation.requestId = ""; conversation.transport = ""
        conversation.refreshing = false
        state.status = "Your phone did not answer"
      }
      if !state.simRequest.isEmpty, state.simDeadline <= time {
        cancelQueued(state.simRequest)
        state.simRequest = ""; state.simTransport = ""; state.simDeadline = 0
        state.simEntries = []
        state.simChoice = 0
      }
      if let search = state.search, !search.requestId.isEmpty, search.deadline <= time {
        cancelQueued(search.requestId)
        search.requestId = ""; search.transport = ""; search.deadline = 0
        search.note = "Your phone did not answer"
      }
      if let send = state.send, send.deadline <= time {
        cancelQueued(send.requestId)
        state.send = nil
        state.status = "Not confirmed; it may have been sent"
        failures.append(failureNote(k, links(for: k).first?.channel.descriptor.peer.deviceName ?? "", send.address, send.threadId))
      }
      state.known = state.known.filter { $0.value > time }
      state.contents.removeAll { $0.expiry <= time }
      state.assemblies = state.assemblies.filter { $0.value.deadline > time }
    }
    for link in links.values { link.queue.removeAll { $0.deadline <= time } }
    for note in failures { Task { await notifier.post(note) } }
    schedule()
  }

  private func failureNote(_ peerKey: String, _ peerName: String, _ address: String, _ threadId: String) -> SmsNotification {
    SmsNotification(identifier: smsNotificationPrefix + "failed-" + UUID().uuidString.lowercased(),
      peerKey: peerKey, peerName: peerName, address: address, threadId: threadId,
      threadIdentifier: smsNormalizedAddress(address), body: "", failure: true)
  }

  private func issueThreads(_ state: PeerState, _ link: Link, _ k: String, firstPage: Bool) {
    let requestId = UUID().uuidString.lowercased()
    state.threadRequest = requestId
    state.threadCards = [:]
    state.threadTransport = link.channel.descriptor.transport
    state.threadDeadline = requestDeadline(link.channel.descriptor.transport)
    state.threadFirstPage = firstPage
    state.status = "Loading conversations…"
    enqueue(link, SmsMessage(kind: 2, fields: [.text(requestId),
      .integer(firstPage ? 0 : state.threadNextMillis), .text(firstPage ? "" : state.threadNextThreadId)]))
    schedule()
  }

  private func recordThread(_ state: PeerState, _ m: SmsMessage) -> Bool {
    // Records are only accepted while their request is the active one; late records change nothing.
    guard !state.threadRequest.isEmpty, m.text(0) == state.threadRequest else { return false }
    let normalized = smsNormalizedAddress(m.text(2))
    guard !normalized.isEmpty else { return false }
    let card = SmsThreadCard(key: normalized, threadId: m.text(1), address: m.text(2),
      snippet: smsTruncate(smsSanitizeText(m.text(3)), maxBytes: 160),
      dateMillis: smsClampDate(m.number(4)), unreadCount: min(m.number(5), SmsMessage.maxDate))
    state.threadCards[normalized] = card
    // Paint each card as it arrives; a live card that is already newer keeps its snippet and stays flagged.
    if let index = state.threads.firstIndex(where: { $0.key == normalized }) {
      var existing = state.threads[index]
      if card.dateMillis >= existing.dateMillis {
        existing.snippet = card.snippet
        existing.dateMillis = card.dateMillis
        existing.address = card.address
        existing.unreadCount = card.unreadCount
        existing.live = false
      }
      existing.threadId = card.threadId
      state.threads[index] = existing
    } else {
      state.threads.append(card)
    }
    orderThreads(state)
    return true
  }

  private func finishThreads(_ state: PeerState, _ m: SmsMessage) -> Bool {
    guard !state.threadRequest.isEmpty, m.text(0) == state.threadRequest else { return false }
    let firstPage = state.threadFirstPage
    state.threadRequest = ""; state.threadTransport = ""; state.threadDeadline = 0
    state.threadFirstPage = true
    switch m.number(1) {
    case 0:
      // A first page is a snapshot: provider cards it no longer reports disappear, while a live card survives
      // unless the snapshot is at least as new. Older pages only add to what the list already shows.
      if firstPage {
        var merged: [String: SmsThreadCard] = [:]
        for card in state.threads where card.live { merged[card.key] = card }
        for card in state.threadCards.values {
          if let existing = merged[card.key], existing.dateMillis > card.dateMillis { continue }
          merged[card.key] = card
        }
        state.threads = Array(merged.values)
        orderThreads(state)
      }
      let terminal = m.number(2) == 0 && m.text(3).isEmpty
      state.threadNextMillis = terminal ? 0 : m.number(2)
      state.threadNextThreadId = terminal ? "" : m.text(3)
      state.threadMore = !terminal
      for (normalized, card) in state.threadCards {
        guard let conversation = conversation(state, normalized) else { continue }
        if conversation.threadId != card.threadId {
          conversation.threadId = card.threadId
          conversation.nextBeforeMillis = 0
          conversation.nextBeforeMessageId = ""
          conversation.more = false
        }
      }
      state.status = state.threads.isEmpty ? "No conversations on your phone" : "\(state.threads.count) conversations"
    case 1: state.status = "Allow SMS access on your phone to read conversations"
    default: state.status = "Conversations are unavailable"
    }
    state.threadCards = [:]
    schedule()
    return true
  }

  private func beginStream(_ state: PeerState, _ m: SmsMessage, _ descriptor: ChannelDescriptor) -> Bool {
    let streamId = m.text(0)
    let requestId = m.text(1)
    if !requestId.isEmpty {
      let history = state.conversations.values.contains { $0.requestId == requestId && $0.transport == descriptor.transport }
      let searching = state.search?.requestId == requestId && state.search?.transport == descriptor.transport
      if !history && !searching { return false }
    }
    if let existing = state.assemblies[streamId] {
      if existing.descriptor == descriptor, existing.begin == m { return true }
      state.assemblies[streamId] = nil
      // A conflicting duplicate on one channel is invalid; a retry on the other channel restarts the stream.
      if existing.descriptor == descriptor {
        if existing.requestId.isEmpty { ack(descriptor, streamId, 6) }
        return true
      }
    }
    guard state.assemblies.count < 16 else { if requestId.isEmpty { ack(descriptor, streamId, 2) }; return false }
    state.assemblies[streamId] = Assembly(descriptor, m, deadline: requestDeadline(descriptor.transport))
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
    guard live(descriptor), peers[key(descriptor.peer)] === state,
      state.assemblies[streamId] === assembly, assembly.deadline > now(),
      assembly.requestId.isEmpty || state.conversations.values.contains(where: { $0.requestId == assembly.requestId })
        || state.search?.requestId == assembly.requestId else { return .discarded }
    state.assemblies[streamId] = nil
    guard let text else {
      if assembly.requestId.isEmpty { ack(descriptor, streamId, 6) }
      return .handled
    }
    // Search hits stay in the peer's search buffer; they never touch conversations, threads or notifications.
    if assembly.requestId.isEmpty {
      ack(descriptor, streamId, 0)
      await admitLive(state, assembly, body: text, digest: digest, peer: descriptor.peer)
    } else if state.search?.requestId == assembly.requestId {
      admitSearch(state, assembly, body: text)
    } else {
      admitProvider(state, assembly, body: text, digest: digest)
    }
    return .handled
  }

  private func admitLive(_ state: PeerState, _ assembly: Assembly, body: String, digest: Data, peer: DeviceIdentity) async {
    let time = now()
    let normalized = smsNormalizedAddress(assembly.address)
    let mark = state.contents.firstIndex { contentMatches($0, assembly, digest: digest, normalized: normalized) && $0.expiry > time }
    // A provider copy of the same message owns its row, but only a delivered notification suppresses the next one:
    // an event that lands after the panel already fetched the provider copy still announces the message.
    let announced = mark.map { state.contents[$0].notified } ?? false
    let duplicate = state.known[assembly.messageId] != nil || mark != nil
    state.known[assembly.messageId] = time + 600
    if let index = mark {
      state.contents[index].expiry = time + 600
      if assembly.messageId.hasPrefix("live:") { state.contents[index].liveMessageId = assembly.messageId }
    } else {
      state.contents.append(ContentMark(address: normalized, digest: digest, dateMillis: assembly.dateMillis,
        expiry: time + 600, notified: false, liveMessageId: assembly.messageId, direction: assembly.direction,
        subscriptionId: assembly.subscriptionId))
    }
    state.liveReceived += 1
    if duplicate { state.liveSuppressed += 1 }
    guard let conversation = conversation(state, normalized) else { return }
    if !duplicate {
      let row = SmsMessageRow(messageId: assembly.messageId, address: assembly.address, dateMillis: assembly.dateMillis,
        direction: assembly.direction, unread: assembly.unread, body: body, digest: digest,
        subscriptionId: assembly.subscriptionId)
      conversation.live.append(row)
      upsertCard(state, address: assembly.address, snippet: body, dateMillis: assembly.dateMillis, unread: assembly.unread ? 1 : 0)
    }
    if announced { return }
    state.status = "Message received"
    let outcome = await notifier.post(SmsNotification(identifier: smsNotificationPrefix + assembly.messageId, peerKey: key(peer),
      peerName: peer.deviceName, address: assembly.address, threadId: conversation.threadId,
      threadIdentifier: normalized, body: body, failure: false))
    guard peers[key(peer)] === state, live(assembly.descriptor) else { return }
    if outcome == .submitted || outcome == .duplicate {
      if outcome == .submitted { state.liveNotified += 1 }
      if let index = state.contents.firstIndex(where: {
        contentMatches($0, assembly, digest: digest, normalized: normalized)
      }) { state.contents[index].notified = true }
    }
    schedule()
  }

  /** One content key with live-ID tolerance and subscription awareness, so two SIM copies never collapse. */
  private func contentMatches(_ mark: ContentMark, _ assembly: Assembly, digest: Data, normalized: String) -> Bool {
    guard mark.direction == assembly.direction, mark.address == normalized, mark.digest == digest,
      abs(mark.dateMillis - assembly.dateMillis) <= 5000 else { return false }
    guard mark.subscriptionId == 0 || assembly.subscriptionId == 0 || mark.subscriptionId == assembly.subscriptionId else { return false }
    return mark.liveMessageId == nil || mark.liveMessageId == assembly.messageId || !assembly.messageId.hasPrefix("live:")
  }

  private func admitProvider(_ state: PeerState, _ assembly: Assembly, body: String, digest: Data) {
    guard let (normalized, conversation) = state.conversations.first(where: { $0.value.requestId == assembly.requestId }) else { return }
    let time = now()
    state.known[assembly.messageId] = time + 600
    // The provider copy never notifies; an existing mark keeps the announced state its live copy may have set.
    if let index = state.contents.firstIndex(where: {
      contentMatches($0, assembly, digest: digest, normalized: normalized)
    }) {
      state.contents[index].expiry = time + 600
    } else {
      state.contents.append(ContentMark(address: normalized, digest: digest, dateMillis: assembly.dateMillis,
        expiry: time + 600, notified: false, direction: assembly.direction, subscriptionId: assembly.subscriptionId))
    }
    // The provider record wins: its live copy is replaced and an existing posted notification is untouched.
    if let index = conversation.live.firstIndex(where: {
      $0.direction == assembly.direction && $0.digest == digest && abs($0.dateMillis - assembly.dateMillis) <= 5000 &&
        smsNormalizedAddress($0.address) == normalized &&
        ($0.subscriptionId == 0 || assembly.subscriptionId == 0 || $0.subscriptionId == assembly.subscriptionId)
    }) { conversation.live.remove(at: index) }
    conversation.rows.removeAll { $0.messageId == assembly.messageId }
    conversation.rows.append(SmsMessageRow(messageId: assembly.messageId, address: assembly.address, dateMillis: assembly.dateMillis,
      direction: assembly.direction, unread: assembly.unread, body: body, digest: digest, subscriptionId: assembly.subscriptionId))
    if let index = state.threads.firstIndex(where: { $0.key == normalized }) {
      var card = state.threads[index]
      card.threadId = assembly.threadId
      state.threads[index] = card
    }
  }

  /** A search hit adds nothing to live dedupe, the thread list or notification state. */
  private func admitSearch(_ state: PeerState, _ assembly: Assembly, body: String) {
    guard let search = state.search, search.requestId == assembly.requestId,
      search.results.count < 200, !search.results.contains(where: { $0.messageId == assembly.messageId }) else { return }
    search.results.append(SmsSearchRow(messageId: assembly.messageId, threadId: assembly.threadId,
      address: assembly.address, dateMillis: assembly.dateMillis, direction: assembly.direction, body: body,
      subscriptionId: assembly.subscriptionId))
  }

  private func finishSearch(_ state: PeerState, _ m: SmsMessage) -> Bool {
    guard let search = state.search, !search.requestId.isEmpty, search.requestId == m.text(0) else { return false }
    search.requestId = ""; search.transport = ""; search.deadline = 0
    switch m.number(1) {
    case 0:
      // Cursors advance only on success; a zero pair is the terminal page.
      search.pages += 1
      let terminal = m.number(2) == 0 && m.text(3).isEmpty
      search.nextBeforeMillis = terminal ? 0 : m.number(2)
      search.nextBeforeMessageId = terminal ? "" : m.text(3)
      search.more = !terminal
      if search.results.isEmpty { search.note = "No matching messages" }
      else if search.more && searchCapped(search) { search.note = "Refine the search" }
      else { search.note = "\(search.results.count) results" }
    case 1: search.note = "Allow SMS access on your phone to search messages"
    case 4: search.note = "Search could not complete on the phone"
    case 5: search.note = "Search is unavailable"
    case 6: search.note = "The search query was rejected"
    default: search.note = "Search is unavailable"
    }
    schedule()
    return true
  }

  /** A listing is only kept when it offers a real second choice; everything else stays silent and on the default. */
  private func finishSims(_ state: PeerState, _ m: SmsMessage) -> Bool {
    guard !state.simRequest.isEmpty, m.text(0) == state.simRequest else { return false }
    state.simRequest = ""; state.simTransport = ""; state.simDeadline = 0
    state.simEntries = m.number(1) == 0 ? simEntries(m) : []
    if state.simEntries.count < 2 { state.simEntries = [] }
    if !state.simEntries.contains(where: { $0.subscriptionId == state.simChoice }) { state.simChoice = 0 }
    schedule()
    return true
  }

  private func simEntries(_ m: SmsMessage) -> [SmsSimEntry] {
    guard case .array(let rows) = m.fields[2] else { return [] }
    return rows.compactMap { row in
      guard case .array(let cells) = row, cells.count == 4,
        case .integer(let subscriptionId) = cells[0], case .integer(let slotIndex) = cells[1],
        case .text(let label) = cells[2], case .bool(let isDefault) = cells[3] else { return nil }
      return SmsSimEntry(subscriptionId: subscriptionId, slotIndex: slotIndex, label: label, isDefault: isDefault)
    }
  }

  private func finishHistory(_ state: PeerState, _ m: SmsMessage) -> Bool {
    guard let (_, conversation) = state.conversations.first(where: { $0.value.requestId == m.text(0) }) else { return false }
    let refreshing = conversation.refreshing
    conversation.requestId = ""; conversation.transport = ""; conversation.deadline = 0; conversation.refreshing = false
    guard m.number(1) == 0 else {
      // A failed newest-page refresh leaves older paging state untouched; a failed older page stops offering more.
      if !refreshing { conversation.more = false }
      state.status = m.number(1) == 1 ? "Allow SMS access on your phone to read messages"
        : m.number(1) == 4 ? "This timestamp group is too large to page" : "Messages are unavailable"
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
        body: send.text, digest: Data(SHA256.hash(data: Data(send.text.utf8))),
        subscriptionId: send.subscriptionId))
      upsertCard(state, address: send.address, snippet: send.text, dateMillis: stamp, unread: 0)
      state.status = "Sent"
    } else {
      state.status = code == 1 ? "Allow SMS on your phone to send replies" : code == 5 ? "Not confirmed; it may have been sent" : "The reply was rejected"
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
    orderThreads(state)
  }

  /** The list reads newest first with a stable key tie-break, so a live message moves its card up at once. */
  private func orderThreads(_ state: PeerState) {
    state.threads.sort {
      $0.dateMillis != $1.dateMillis ? $0.dateMillis > $1.dateMillis : $0.key < $1.key
    }
  }

  private func ack(_ descriptor: ChannelDescriptor, _ streamId: String, _ code: Int64) {
    guard live(descriptor), let link = links[descriptor.transport] else { return }
    enqueue(link, SmsMessage(kind: 9, fields: [.text(streamId), .integer(code)]))
  }

  private func schedule() {
    timer?.cancel(); timer = nil
    var deadlines = links.values.flatMap { $0.queue.map(\.deadline) }
    for state in peers.values {
      if !state.threadRequest.isEmpty { deadlines.append(state.threadDeadline) }
      deadlines.append(contentsOf: state.conversations.values.filter { !$0.requestId.isEmpty }.map(\.deadline))
      if !state.simRequest.isEmpty { deadlines.append(state.simDeadline) }
      if let search = state.search, !search.requestId.isEmpty { deadlines.append(search.deadline) }
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

  private func cancelQueued(_ owner: String) {
    for link in links.values { link.queue.removeAll { $0.owner == owner } }
  }

  private func enqueue(_ link: Link, _ message: SmsMessage) {
    guard live(link.channel.descriptor), link.queue.count < 32 else { return }
    let owner = message.kind == 1 ? "" : message.text(0)
    link.queue.append(Queued(message, owner: owner, deadline: requestDeadline(link.channel.descriptor.transport)))
    pump(link)
    schedule()
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
          if first.deadline <= self.now() { link.queue.removeFirst(); continue }
          do { try await link.channel.sendData(first.message.encode()) }
          catch is SessionBackpressure { break }
          catch {
            let peer = self.peers[self.key(link.channel.descriptor.peer)]
            self.retired(link.channel.descriptor)
            peer?.status = "SMS submission was not confirmed"
            return
          }
          if link.queue.first === first { link.queue.removeFirst() }
        }
      } while link.wake && self.live(link.channel.descriptor)
    }
  }
}
