// SPDX-License-Identifier: GPL-3.0-or-later
// Serially owns generation-bound Find Device requests, replay floors and native alert lifetimes.
import Foundation
import Observation

@MainActor protocol FindDeviceNotifying: AnyObject {
  func post(identifier: String, peerName: String) async -> FindResult
  func clear(identifier: String)
}

@Observable @MainActor final class MacFindDeviceModel: FeatureHandler {
  final class History {
    var processing: Int64?
    var counter: Int64 = 0
    var highWater: Int64 = 0
    var results: [Int64: FindDeviceMessage] = [:]
    var order: [Int64] = []
  }
  @Observable final class Link {
    let channel: any SecuredChannel
    let history: History
    var capable = false
    var queue: [(FindDeviceMessage, TimeInterval)] = []
    var sending = false
    var wake = false
    init(_ channel: any SecuredChannel, history: History) { self.channel = channel; self.history = history }
  }
  private struct Pending {
    let descriptor: ChannelDescriptor
    let message: FindDeviceMessage
    let deadline: TimeInterval
  }
  private struct Alert {
    let descriptor: ChannelDescriptor
    let identifier: String
    let deadline: TimeInterval
  }
  private let notifier: any FindDeviceNotifying
  private let now: () -> TimeInterval
  private var links: [String: Link] = [:]
  private var pending: Pending?
  private var alerts: [String: Alert] = [:]
  private var timer: Task<Void, Never>?
  private(set) var feedbackKey = "find_idle"
  private(set) var feedbackPeer: DeviceIdentity?
  var busy: Bool { pending != nil }
  init(notifier: any FindDeviceNotifying, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.notifier = notifier; self.now = now
  }
  private func peerKey(_ d: ChannelDescriptor) -> String { d.peer.deviceId + ":" + d.peer.fingerprint }
  private func live(_ d: ChannelDescriptor) -> Bool { links[d.transport]?.channel.descriptor == d }
  func supports(_ peer: DeviceIdentity) -> Bool { selected(peer) != nil }
  func canFind(_ peer: DeviceIdentity) -> Bool { selected(peer) != nil && !busy }
  private func selected(_ peer: DeviceIdentity) -> Link? {
    ["lan", "ble"].compactMap { links[$0] }.first {
      $0.capable && $0.channel.descriptor.peer.deviceId == peer.deviceId && $0.channel.descriptor.peer.fingerprint == peer.fingerprint
    }
  }
  func available(_ channel: any SecuredChannel) {
    let d = channel.descriptor
    if live(d) { return }
    if let old = links[d.transport] { retired(old.channel.descriptor) }
    // Coexisting transports share replay floors so switching channels cannot revive a dismissed request.
    let history = links.values.first { peerKey($0.channel.descriptor) == peerKey(d) }?.history ?? History()
    let link = Link(channel, history: history); links[d.transport] = link
    enqueue(FindDeviceMessage(kind: 1), link)
  }
  func retired(_ descriptor: ChannelDescriptor) {
    guard live(descriptor) else { return }
    links[descriptor.transport] = nil
    if pending?.descriptor == descriptor { pending = nil; feedbackKey = "find_disconnected" }
    for alert in Array(alerts.values) where alert.descriptor == descriptor { dismiss(identifier: alert.identifier) }
    schedule()
  }
  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard live(descriptor), let link = links[descriptor.transport] else { return }
    if link.sending { link.wake = true } else { pump(link) }
  }
  func find(_ peer: DeviceIdentity) {
    expire()
    guard !busy, let link = selected(peer), link.history.counter < 4294967295, link.queue.count < 8 else { return }
    link.history.counter += 1
    let message = FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: link.history.counter)
    pending = Pending(descriptor: link.channel.descriptor, message: message, deadline: now() + 10)
    feedbackKey = "find_waiting"
    feedbackPeer = peer
    enqueue(message, link)
  }
  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    let message: FindDeviceMessage
    do { guard let decoded = try FindDeviceMessage.decode(bytes) else { return .unrecognized }; message = decoded }
    catch { return .discarded }
    expire()
    guard live(descriptor), let link = links[descriptor.transport] else { return .discarded }
    if message.kind == 1 { link.capable = true; return .handled }
    guard link.capable else { return .discarded }
    if message.kind == 3 {
      guard let p = pending, p.descriptor == descriptor, p.message.id == message.id, p.message.sequence == message.sequence else { return .discarded }
      pending = nil
      feedbackKey = ["find_submitted", "find_blocked", "find_stale", "find_busy", "find_failed"][Int(message.result)]
      schedule(); return .handled
    }
    if link.history.processing == message.sequence { return .handled }
    if let cached = link.history.results[message.sequence] {
      enqueue(cached.id == message.id ? cached : reply(message, .stale), link); return .handled
    }
    guard message.sequence > link.history.highWater else { enqueue(reply(message, .stale), link); return .discarded }
    link.history.highWater = message.sequence
    if link.history.results.values.contains(where: { $0.id == message.id }) { enqueue(reply(message, .stale), link); return .discarded }
    guard link.queue.count < 8 else { return .discarded }
    // Record admission before any suspension; duplicate in-flight requests cannot create another alert.
    remember(reply(message, .stale), link)
    let key = peerKey(descriptor)
    guard alerts[key] == nil, link.history.processing == nil else { let response = reply(message, .busy); remember(response, link); enqueue(response, link); return .handled }
    link.history.processing = message.sequence
    defer { link.history.processing = nil }
    let identifier = "find-device-" + UUID().uuidString.lowercased()
    let alert = Alert(descriptor: descriptor, identifier: identifier, deadline: now() + 60)
    alerts[key] = alert; schedule()
    let result = await notifier.post(identifier: identifier, peerName: descriptor.peer.deviceName)
    expire()
    guard live(descriptor), alerts[key]?.identifier == identifier else {
      notifier.clear(identifier: identifier); return .discarded
    }
    if result != .submitted { dismiss(identifier: identifier) }
    let response = reply(message, result)
    remember(response, link); enqueue(response, link)
    return .handled
  }
  private func reply(_ m: FindDeviceMessage, _ result: FindResult) -> FindDeviceMessage {
    FindDeviceMessage(kind: 3, id: m.id, sequence: m.sequence, result: result.rawValue)
  }
  private func remember(_ result: FindDeviceMessage, _ link: Link) {
    if link.history.results[result.sequence] == nil { link.history.order.append(result.sequence) }
    link.history.results[result.sequence] = result
    if link.history.order.count > 32 { link.history.results[link.history.order.removeFirst()] = nil }
  }
  func dismiss(identifier: String) {
    guard let key = alerts.first(where: { $0.value.identifier == identifier })?.key else { return }
    alerts[key] = nil; notifier.clear(identifier: identifier); schedule()
  }
  func expire() {
    let time = now()
    if let p = pending, p.deadline <= time {
      pending = nil; feedbackKey = "find_timeout"
      for link in links.values { link.queue.removeAll { $0.0 == p.message } }
    }
    for alert in Array(alerts.values) where alert.deadline <= time { dismiss(identifier: alert.identifier) }
    for link in links.values { link.queue.removeAll { $0.1 <= time } }
    schedule()
  }
  private func schedule() {
    timer?.cancel(); timer = nil
    let deadlines = alerts.values.map(\.deadline) + (pending.map { [$0.deadline] } ?? []) + links.values.flatMap { $0.queue.map { $0.1 } }
    guard let next = deadlines.min() else { return }
    let delay = max(0.001, next - now())
    timer = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      self?.expire()
    }
  }
  private func enqueue(_ message: FindDeviceMessage, _ link: Link) {
    guard live(link.channel.descriptor), link.queue.count < 8 else { return }
    if !link.queue.contains(where: { $0.0 == message }) { link.queue.append((message, now() + 10)) }
    schedule(); pump(link)
  }
  private func pump(_ link: Link) {
    guard !link.sending else { return }
    link.sending = true
    Task { [weak self] in
      guard let self else { return }
      defer { link.sending = false; self.schedule() }
      repeat {
        link.wake = false
        while self.live(link.channel.descriptor), let first = link.queue.first {
          if first.1 <= self.now() { link.queue.removeFirst(); continue }
          do {
            try await link.channel.sendData(first.0.encode())
            guard self.live(link.channel.descriptor) else { return }
            if link.queue.first?.0 == first.0 { link.queue.removeFirst() }
          } catch is SessionBackpressure { break }
          catch {
            if self.pending?.descriptor == link.channel.descriptor {
              self.pending = nil; self.feedbackKey = "find_failed"
            }
            link.queue.removeAll(); return
          }
        }
      } while link.wake && self.live(link.channel.descriptor)
    }
  }
}
