// SPDX-License-Identifier: GPL-3.0-or-later
// Serially owns clipboard delivery, cross-transport deduplication and opt-in pasteboard observation.
import AppKit
import CryptoKit
import Foundation
import Observation

struct ClipboardActivity: Identifiable {
  let id = UUID()
  let received: Bool
  let timestamp = Date()
  let deadline: TimeInterval
  let credential: String
  let sample: ClipboardSample?
  var textPreview: String? { sample.map { String($0.text.prefix(240)) } }
}

@MainActor @Observable final class MacClipboardModel: FeatureHandler {
  @Observable final class Link {
    let channel: any SecuredChannel
    var epoch: String?
    var announced = false
    var remoteAutomatic = false
    var settingsRevision: Int64 = 0
    var queue: [ClipboardMessage] = []
    var sending = false
    var wake = false
    var capacity: [UUID: CheckedContinuation<Void, Never>] = [:]
    init(_ channel: any SecuredChannel) { self.channel = channel }
  }
  private final class Incoming {
    let begin: ClipboardMessage
    let baseline: String?
    let deadline: TimeInterval
    var fragments: [Data] = []
    var committing = false
    init(_ begin: ClipboardMessage, baseline: String?, deadline: TimeInterval) {
      self.begin = begin; self.baseline = baseline; self.deadline = deadline
    }
  }
  private struct Terminal { let begin: ClipboardMessage; let code: Int64; let expiry: TimeInterval }
  private final class History {
    var epoch: String
    var floor: Int64 = 0
    var incoming: Incoming?
    var terminal: [String: Terminal] = [:]
    init(_ epoch: String) { self.epoch = epoch }
  }
  private final class Outgoing {
    let peer: DeviceIdentity
    let begin: ClipboardMessage
    let data: Data
    let deadline: TimeInterval
    let sample: ClipboardSample
    var attempted: [ChannelDescriptor] = []
    var result: Int64?
    var task: Task<Void, Never>?
    var resultWait: CheckedContinuation<Void, Never>?
    var resultTimer: Task<Void, Never>?
    init(peer: DeviceIdentity, begin: ClipboardMessage, data: Data, deadline: TimeInterval, sample: ClipboardSample) {
      self.peer = peer; self.begin = begin; self.data = data; self.deadline = deadline; self.sample = sample
    }
    func wake() { resultTimer?.cancel(); resultTimer = nil; let c = resultWait; resultWait = nil; c?.resume() }
  }
  private let native: any NativeClipboard
  let preferences: ClipboardPreferences
  let history: ClipboardHistory
  private var historyToken: String?
  private let now: () -> TimeInterval
  private let wait: @MainActor (TimeInterval) async throws -> Void
  private var links: [String: Link] = [:]
  private var histories: [String: History] = [:]
  private var settingRevisions: [String: Int64] = [:]
  private let epoch = UUID().uuidString.lowercased()
  private var revision: Int64 = 0
  private var outgoing: Outgoing?
  private var pending: ClipboardSample?
  private var sampling = 0
  private var preparingAutomatic = false
  private var observedToken: String?
  private var applying = false
  private var sleeping = false
  private var timer: Task<Void, Never>?
  private var notifications: [NSObjectProtocol] = []
  private(set) var selected: DeviceIdentity?
  private(set) var busy = false
  private(set) var automatic = false
  private(set) var status = "Ready to share text"
  private(set) var preview: ClipboardSample?
  private(set) var recent: ClipboardActivity?
  var onLanRequired: () -> Void = {}
  var automaticAccessAllowed: Bool { native.automaticAccessAllowed }
  init(native: any NativeClipboard, history: ClipboardHistory = ClipboardHistory(), preferences: ClipboardPreferences = ClipboardPreferences(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, wait: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
    self.history = history
    self.native = native; self.preferences = preferences; self.now = now; self.wait = wait
    history.onChanged = { [weak self] in self?.updateObservation() }
  }
  func installLifecycle() {
    guard notifications.isEmpty else { return }
    let center = NSWorkspace.shared.notificationCenter
    notifications.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.sleeping = true; self?.cancel(); self?.updateObservation() }
    })
    notifications.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.sleeping = false; self?.updateObservation() }
    })
  }
  func connected(_ peer: DeviceIdentity) -> Bool { links.values.contains { key($0.channel.descriptor.peer) == key(peer) } }
  func supports(_ peer: DeviceIdentity) -> Bool { !candidates(peer).isEmpty }
  func enabled(_ peer: DeviceIdentity) -> Bool { preferences.enabled(peer) }
  private func key(_ peer: DeviceIdentity) -> String { preferences.key(peer) }
  private func live(_ d: ChannelDescriptor) -> Bool { links[d.transport]?.channel.descriptor == d }
  private func candidates(_ peer: DeviceIdentity) -> [Link] { [links["lan"], links["ble"]].compactMap { $0 }.filter { $0.epoch != nil && $0.announced && key($0.channel.descriptor.peer) == key(peer) } }
  func select(_ peer: DeviceIdentity?) {
    guard selected.map(key) != peer.map(key) else { return }
    cancel(); selected = peer; automatic = peer.map(preferences.enabled) ?? false
    preview = nil; observedToken = nil; updateObservation()
  }
  func setAutomatic(_ value: Bool) {
    guard let peer = selected else { return }
    preferences.set(peer, value); automatic = value
    let k = key(peer); settingRevisions[k] = (settingRevisions[k] ?? 1) + 1
    for link in links.values where key(link.channel.descriptor.peer) == k { settings(link) }
    if !value {
      if preparingAutomatic || outgoing?.begin.number(3) == 1 { cancel() }
      pending = nil
      if let incoming = histories[k]?.incoming, incoming.begin.number(3) == 1 { finishIncoming(k, incoming, 1, nil) }
    }
    observedToken = nil; updateObservation()
    if value { sampleAutomatic() }
  }
  func refreshAccess() { updateObservation() }
  private func updateObservation() {
    native.observe(!sleeping && (history.enabled || automatic && selected.map(supports) == true) && native.automaticAccessAllowed) { [weak self] in
      guard let self, !self.applying else { return }; self.sampleAutomatic()
    }
    if (automatic || history.enabled) && !native.automaticAccessAllowed { status = "Allow pasteboard access in System Settings, or paste text below" }
  }
  private func sampleAutomatic() {
    guard !sleeping, native.automaticAccessAllowed, let sample = native.read() else { return }
    captureLocal(sample)
    guard automatic, let peer = selected, candidates(peer).contains(where: { $0.remoteAutomatic }) else { return }
    guard sample.token != observedToken else { return }; observedToken = sample.token
    pending = nil
    if preparingAutomatic { sampling += 1; busy = false; preparingAutomatic = false }
    guard !sample.sensitive, !sample.excluded else { return }
    submit(sample, auto: true)
  }
  private func captureLocal(_ sample: ClipboardSample) {
    guard history.enabled else { return }
    guard sample.token.isEmpty || sample.token != historyToken else { return }; historyToken = sample.token
    history.record(sample, origin: "mac")
  }
  func copyHistory(_ entry: ClipboardHistoryEntry) {
    applying = true
    status = native.write(entry.text, sensitive: false) ? "Copied" : "Could not copy text"
    applying = false
  }
  func sendHistory(_ entry: ClipboardHistoryEntry) { submit(ClipboardSample(text: entry.text), auto: false) }
  func sendConfirmed(_ sample: ClipboardSample) { submit(sample, auto: false) }
  func clearPreview() { preview = nil }
  func inspect() { preview = native.read(); if let preview { captureLocal(preview) }; if preview == nil { status = "Copy plain text, or paste text below" }; updateObservation() }
  func send(pasted: String? = nil) {
    guard let sample = pasted.map({ ClipboardSample(text: $0) }) ?? native.read() else { status = "Copy plain text, or paste text below"; return }
    captureLocal(sample)
    preview = sample
    guard !sample.sensitive else { status = "Confirm sending sensitive text"; return }
    submit(sample, auto: false)
  }
  private func submit(_ sample: ClipboardSample, auto: Bool) {
    guard let peer = selected else { return }
    guard candidates(peer).contains(where: { !auto || $0.remoteAutomatic }) else { status = "Connect first, or enable automatic sharing on both devices"; return }
    if busy { if auto { pending = sample }; return }
    guard !sample.text.isEmpty, !sample.text.contains("\0"), sample.text.utf8.count <= 65536 else { status = "Choose plain text up to 64 KiB"; return }
    busy = true; preparingAutomatic = auto; sampling += 1; let generation = sampling
    Task { [weak self] in
      let pair = await Task.detached { let data = Data(sample.text.utf8); return (data, Data(SHA256.hash(data: data))) }.value
      guard let self, generation == self.sampling, self.selected.map(self.key) == self.key(peer), !auto || self.automatic else { return }
      self.preparingAutomatic = false
      guard self.revision < 4294967295 else { self.busy = false; self.status = "Clipboard revision limit reached"; return }
      self.revision += 1
      let begin = ClipboardMessage(kind: 3, fields: [.text(self.epoch), .integer(self.revision), .text(UUID().uuidString.lowercased()), .integer(auto ? 1 : 0), .bool(sample.sensitive), .integer(Int64(pair.0.count)), .integer(Int64((pair.0.count + 3071) / 3072)), .bytes(pair.1)])
      let item = Outgoing(peer: peer, begin: begin, data: pair.0, deadline: self.now() + 30, sample: sample)
      self.outgoing = item; self.status = "Sending to \(peer.deviceName)"; self.onLanRequired()
      item.task = Task { [weak self] in await self?.deliver(item) }; self.schedule()
    }
  }
  func available(_ channel: any SecuredChannel) {
    let d = channel.descriptor
    guard !live(d) else { return }
    if let old = links[d.transport] { retired(old.channel.descriptor) }
    let link = Link(channel); links[d.transport] = link
    enqueue(link, ClipboardMessage(kind: 1, fields: [.text(epoch), .integer(65536), .integer(3072)])); settings(link)
    if selected == nil { select(d.peer) }
  }
  private func settings(_ link: Link) {
    let peer = link.channel.descriptor.peer; let k = key(peer)
    if settingRevisions[k] == nil { settingRevisions[k] = 1 }
    link.queue.removeAll { $0.kind == 2 }
    enqueue(link, ClipboardMessage(kind: 2, fields: [.integer(settingRevisions[k]!), .bool(preferences.enabled(peer))]))
  }
  func retired(_ d: ChannelDescriptor) {
    guard live(d), let link = links.removeValue(forKey: d.transport) else { return }
    let waking = Array(link.capacity.values); link.capacity.removeAll(); waking.forEach { $0.resume() }
    if outgoing?.attempted.contains(d) == true { outgoing?.wake() }
    let k = key(d.peer)
    if !links.values.contains(where: { key($0.channel.descriptor.peer) == k }) {
      histories[k]?.incoming = nil
      if outgoing.map({ key($0.peer) }) == k { cancel() }
      if selected.map(key) == k { pending = nil; preview = nil; sampling += 1; preparingAutomatic = false; busy = false }
    }
    updateObservation(); schedule()
  }
  func capacityAvailable(_ d: ChannelDescriptor) {
    guard live(d), let link = links[d.transport] else { return }
    let waking = Array(link.capacity.values); link.capacity.removeAll(); waking.forEach { $0.resume() }
    if link.sending { link.wake = true } else { pump(link) }
  }
  private func send(_ link: Link, _ message: ClipboardMessage, _ deadline: TimeInterval) async throws {
    while live(link.channel.descriptor) && now() < deadline && !Task.isCancelled {
      do { try await link.channel.sendData(message.encode()); return }
      catch is SessionBackpressure {
        let id = UUID()
        await withCheckedContinuation { c in link.capacity[id] = c }
        link.capacity.removeValue(forKey: id)
      }
    }
    throw CancellationError()
  }
  private func deliver(_ item: Outgoing) async {
    defer {
      item.wake()
      if outgoing === item {
        let messages = ["Clipboard delivered", "Automatic receiving is off on the other device", "Other device is busy", "Newer clipboard item already received", "Newer local copy kept", "Could not write the other clipboard", "Clipboard item rejected", "Clipboard send cancelled"]
        status = item.result.map { messages[Int($0)] } ?? "Delivery unconfirmed"
        if item.result == 0 { recordActivity(item.sample, received: false, peer: item.peer) }
        outgoing = nil; busy = false; preview = nil
        let next = pending; pending = nil
        if let next, automatic, !sleeping { submit(next, auto: true) }
        schedule()
      }
    }
    for _ in 0..<2 {
      guard outgoing === item, now() < item.deadline, !Task.isCancelled,
        let link = candidates(item.peer).first(where: { l in !item.attempted.contains { $0.transport == l.channel.descriptor.transport } && (item.begin.number(3) == 0 || l.remoteAutomatic) }) else { return }
      item.attempted.append(link.channel.descriptor)
      do {
        try await send(link, item.begin, item.deadline)
        for index in 0..<Int(item.begin.number(6)) {
          guard item.result == nil, outgoing === item, !Task.isCancelled else { break }
          let start = index * 3072
          try await send(link, ClipboardMessage(kind: 4, fields: [.text(item.begin.text(2)), .integer(Int64(index)), .bytes(item.data.subdata(in: start..<min(start + 3072, item.data.count)))]), item.deadline)
        }
        if item.result == nil && outgoing === item {
          try await send(link, .id(5, item.begin.text(2)), item.deadline)
          if item.result == nil && live(link.channel.descriptor) && !Task.isCancelled {
            await withCheckedContinuation { c in
              item.resultWait = c
              item.resultTimer = Task {
                do { try await self.wait(min(2, max(0, item.deadline - self.now()))) }
                catch { return }
                item.wake()
              }
            }
          }
        }
      } catch { if Task.isCancelled { return } }
      if item.result != nil { return }
    }
  }
  func handle(_ bytes: Data, on d: ChannelDescriptor) async -> DataHandling {
    let m: ClipboardMessage
    do { guard let decoded = try ClipboardMessage.decode(bytes) else { return .unrecognized }; m = decoded }
    catch { return .discarded }
    expire()
    guard live(d), let link = links[d.transport] else { return .discarded }
    let k = key(d.peer)
    if m.kind == 1 {
      let old = histories[k]
      guard link.epoch == nil || link.epoch == m.text(0) else { return .discarded }
      if let old, old.epoch != m.text(0) {
        guard !links.values.contains(where: { $0 !== link && key($0.channel.descriptor.peer) == k && $0.epoch != nil }) else { return .discarded }
        old.epoch = m.text(0); old.floor = 0; old.incoming = nil
      }
      link.epoch = m.text(0); if old == nil { histories[k] = History(m.text(0)) }
      updateObservation(); return .handled
    }
    guard link.epoch != nil, let h = histories[k] else { return .discarded }
    if m.kind == 2 {
      let peers = links.values.filter { key($0.channel.descriptor.peer) == k }
      let newest = peers.map(\.settingsRevision).max() ?? 0
      guard m.number(0) >= newest, !(m.number(0) == newest && peers.contains { $0.settingsRevision == newest && $0.remoteAutomatic != m.flag(1) }) else { return .discarded }
      for peer in peers { peer.settingsRevision = m.number(0); peer.remoteAutomatic = m.flag(1) }
      return .handled
    }
    if m.kind == 6 {
      guard let item = outgoing, key(item.peer) == k, item.begin.text(2) == m.text(0), item.attempted.contains(d) else { return .discarded }
      item.result = m.number(1); item.wake(); return .handled
    }
    let id = m.text(m.kind == 3 ? 2 : 0)
    if let terminal = h.terminal[id] {
      if m.kind == 3 && terminal.begin != m { enqueue(link, .result(id, 6)); return .discarded }
      if m.kind == 3 || m.kind == 5 { enqueue(link, .result(id, terminal.code)) }
      return .handled
    }
    if m.kind == 3 {
      if let existing = h.incoming, existing.begin.text(2) == id {
        guard existing.begin == m else { enqueue(link, .result(id, 6)); return .discarded }
        return .handled
      }
      let code: Int64? = m.text(0) != h.epoch || m.number(1) <= h.floor ? 3 : m.number(3) == 1 && !preferences.enabled(d.peer) ? 1 : h.incoming != nil || h.terminal.count >= 32 ? 2 : nil
      if let code { enqueue(link, .result(id, code)); return .handled }
      h.floor = m.number(1); h.incoming = Incoming(m, baseline: native.token(), deadline: now() + 30); schedule(); return .handled
    }
    guard let incoming = h.incoming, incoming.begin.text(2) == id else { return .discarded }
    if m.kind == 7 { finishIncoming(k, incoming, 7, link); return .handled }
    guard !incoming.committing else { return .discarded }
    if m.kind == 4 {
      let index = Int(m.number(1)), count = Int(incoming.begin.number(6))
      let expected = index == count - 1 ? Int(incoming.begin.number(5)) - index * 3072 : 3072
      guard index < count, m.bytes(2).count == expected, index <= incoming.fragments.count,
        index == incoming.fragments.count || incoming.fragments[index] == m.bytes(2) else { finishIncoming(k, incoming, 6, link); return .discarded }
      if index == incoming.fragments.count { incoming.fragments.append(m.bytes(2)) }
      return .handled
    }
    guard m.kind == 5 else { return .discarded }
    guard incoming.fragments.count == Int(incoming.begin.number(6)) else { finishIncoming(k, incoming, 6, link); return .discarded }
    incoming.committing = true
    let fragments = incoming.fragments, digest = incoming.begin.bytes(7)
    let text = await Task.detached { () -> String? in
      let data = fragments.reduce(into: Data()) { $0.append($1) }
      guard Data(SHA256.hash(data: data)) == digest, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return nil }; return text
    }.value
    guard histories[k]?.incoming === incoming, now() < incoming.deadline else { expire(); incoming.committing = false; return .discarded }
    let current = native.token()
    let code: Int64
    if text == nil { code = 6 }
    else if incoming.begin.number(3) == 1 && !preferences.enabled(d.peer) { code = 1 }
    else if let baseline = incoming.baseline, let current, current != baseline { code = 4 }
    else {
      applying = true
      code = native.write(text!, sensitive: incoming.begin.flag(4)) ? 0 : 5
      applying = false
    }
    if code == 0, let text {
      let sample = ClipboardSample(text: text, sensitive: incoming.begin.flag(4))
      history.record(sample, origin: "phone", credential: k)
      recordActivity(sample, received: true, peer: d.peer)
    }
    let responseLink = live(d) ? link : links.values.first { key($0.channel.descriptor.peer) == k && $0.epoch == h.epoch }
    finishIncoming(k, incoming, code, responseLink); return .handled
  }
  private func finishIncoming(_ k: String, _ incoming: Incoming, _ code: Int64, _ link: Link?) {
    guard let h = histories[k], h.incoming === incoming else { return }
    h.incoming = nil; h.terminal[incoming.begin.text(2)] = Terminal(begin: incoming.begin, code: code, expiry: now() + 60)
    if let link { enqueue(link, .result(incoming.begin.text(2), code)) }
    if code == 0 { pending = nil }
    status = code == 0 ? "Clipboard received" : "Incoming clipboard not applied"; preview = nil; schedule()
  }
  func cancel() {
    sampling += 1; preparingAutomatic = false; pending = nil; preview = nil
    let item = outgoing; outgoing = nil; busy = false
    item?.task?.cancel(); item?.wake()
    if let item {
      for d in item.attempted where live(d) { if let link = links[d.transport] { enqueue(link, .id(7, item.begin.text(2))) } }
    }
    for link in links.values { let waking = Array(link.capacity.values); link.capacity.removeAll(); waking.forEach { $0.resume() } }
    schedule()
  }
  private func recordActivity(_ sample: ClipboardSample, received: Bool, peer: DeviceIdentity) {
    // Retain one process-local item for five minutes; sensitive/generated text is never retained for preview or Copy.
    recent = ClipboardActivity(received: received, deadline: now() + 300, credential: key(peer), sample: sample.sensitive || sample.excluded ? nil : sample)
    schedule()
  }
  func dismissActivity(_ id: UUID) { if recent?.id == id { recent = nil; schedule() } }
  func copyActivity(_ id: UUID) -> Bool {
    // A stale view action must not copy a replacement item or revive an expired one.
    guard let recent, recent.id == id, recent.deadline > now(), let sample = recent.sample else { return false }
    applying = true
    defer { applying = false }
    return native.write(sample.text, sensitive: sample.sensitive)
  }
  func invalidate() { recent = nil; cancel(); native.observe(false) {}; for d in links.values.map({ $0.channel.descriptor }) { retired(d) }; histories.removeAll(); preview = nil; schedule() }
  func prune(_ peers: [DeviceIdentity], confirmedTrust: Bool = false) {
    preferences.prune(peers)
    if confirmedTrust {
      let keep = Set(peers.map(key)); history.prune(keep)
      if let recent, !keep.contains(recent.credential) { self.recent = nil; schedule() }
    }
    if let selected, !peers.contains(where: { key($0) == key(selected) }) { select(nil); automatic = false }
  }
  func expire() {
    let time = now()
    if let recent, recent.deadline <= time { self.recent = nil }
    for (k, h) in histories {
      h.terminal = h.terminal.filter { $0.value.expiry > time }
      if let incoming = h.incoming, incoming.deadline <= time { finishIncoming(k, incoming, 7, nil) }
    }
    histories = histories.filter { k, h in !h.terminal.isEmpty || h.incoming != nil || links.values.contains { key($0.channel.descriptor.peer) == k } }
    if let outgoing, outgoing.deadline <= time { cancel(); status = "Delivery unconfirmed" }
    schedule()
  }
  private func schedule() {
    timer?.cancel(); timer = nil
    // Reuse the delivery deadline timer so recent activity needs no additional polling loop.
    let deadlines = histories.values.flatMap { h in h.terminal.values.map(\.expiry) + (h.incoming.map { [$0.deadline] } ?? []) } + (outgoing.map { [$0.deadline] } ?? []) + (recent.map { [$0.deadline] } ?? [])
    guard let next = deadlines.min() else { return }
    let delay = max(0.001, next - now()), wait = self.wait
    timer = Task { [weak self] in
      do { try await wait(delay) }
      catch { return }
      self?.expire()
    }
  }
  private func enqueue(_ link: Link, _ message: ClipboardMessage) {
    guard live(link.channel.descriptor), link.queue.count < 8 else { return }
    link.queue.append(message); pump(link)
  }
  private func pump(_ link: Link) {
    guard !link.sending else { return }; link.sending = true
    Task { [weak self] in
      guard let self else { link.sending = false; return }
      defer { link.sending = false }
      repeat {
        link.wake = false
        while self.live(link.channel.descriptor), let first = link.queue.first {
          do { try await link.channel.sendData(first.encode()) }
          catch is SessionBackpressure { break }
          catch { link.queue.removeAll(); return }
          if link.queue.first == first { link.queue.removeFirst() }
          if first.kind == 2 && !link.announced { link.announced = true; self.updateObservation() }
        }
      } while link.wake && self.live(link.channel.descriptor)
    }
  }
}
