// SPDX-License-Identifier: GPL-3.0-or-later
// Arms one authenticated phone session on demand and releases it on every exit.
import Foundation
import Observation

@Observable @MainActor final class MacPhoneInputModel: FeatureHandler {
  private enum StartResult: Int64 { case accepted = 0, busy = 1, unavailable = 2, unsupported = 3 }
  private enum EndReason: Int64 { case localStop = 0, accessUnavailable = 1, invalidInput = 2, captureEnded = 3 }

  @MainActor private final class Outbound {
    enum Purpose: Equatable { case capability, startResult(UUID, Int64), sessionEnded(String, Int64) }
    let id = UUID()
    let bytes: Data
    let purpose: Purpose
    let didSend: (() -> Void)?
    init(_ bytes: Data, purpose: Purpose, didSend: (() -> Void)? = nil) {
      self.bytes = bytes
      self.purpose = purpose
      self.didSend = didSend
    }
  }

  @MainActor private final class Link {
    let channel: any SecuredChannel
    var remoteEvents: Int64 = 0
    var remoteTextBytes: Int64 = 0
    var outgoing = [Outbound]()
    var pendingEnd: Outbound?
    var sending = false
    var wake = false
    init(_ channel: any SecuredChannel) { self.channel = channel }
  }

  private struct PendingStart {
    let id: UUID
    let descriptor: ChannelDescriptor
    let peer: DeviceIdentity
    let ownerID: UUID
    let messageID: String
  }

  private struct ActiveSession {
    let id: String
    let descriptor: ChannelDescriptor
    let ownerID: UUID
    var lastSequence: Int64 = 0
  }

  private let eventAdapter: MacPhoneInputEventAdapter
  private var links: [String: Link] = [:]
  private var pendingStart: PendingStart?
  private var activeSession: ActiveSession?
  private var armedOwnerID: UUID?
  // Phone-started arming ends with its session; a local owner can remain armed between sessions.
  private var automaticOwnerID: UUID?
  private var armedPeer: DeviceIdentity?
  private(set) var eventAccessAvailable: Bool
  private(set) var accessibilityTrusted: Bool
  private(set) var hasStableSigningIdentity: Bool
  // A successful Settings change may not reach this process until it restarts.
  private(set) var eventAccessRequestAttempted = false
  private(set) var statusMessage = "Phone input is off."

  init(eventAdapter: MacPhoneInputEventAdapter = MacPhoneInputEventAdapter()) {
    self.eventAdapter = eventAdapter
    self.eventAccessAvailable = eventAdapter.canPostEvents
    self.accessibilityTrusted = eventAdapter.accessibilityTrusted
    self.hasStableSigningIdentity = eventAdapter.hasStableSigningIdentity
  }

  var isArmed: Bool { armedOwnerID != nil }
  var isReceiving: Bool { activeSession != nil }
  var needsPostEventAccess: Bool { !eventAccessAvailable }
  var permissionGrantMayBeStale: Bool { accessibilityTrusted && !eventAccessAvailable }
  var canOfferPermissionRestart: Bool { eventAccessRequestAttempted && !eventAccessAvailable }
  var targetPeer: DeviceIdentity? { armedPeer }
  var connectedPeer: DeviceIdentity? { links["ble"]?.channel.descriptor.peer }

  func isArmed(by ownerID: UUID) -> Bool { armedOwnerID == ownerID }
  func isArmed(for peer: DeviceIdentity) -> Bool { armedOwnerID != nil && samePeer(armedPeer, peer) }

  // System Settings can revoke event access while a receive session is active.
  func refreshAccessState(collectDiagnostics: Bool = true) {
    if collectDiagnostics {
      accessibilityTrusted = eventAdapter.accessibilityTrusted
      hasStableSigningIdentity = eventAdapter.hasStableSigningIdentity
    }
    let available = eventAdapter.canPostEvents
    if available { eventAccessRequestAttempted = false }
    guard eventAccessAvailable != available else { return }
    eventAccessAvailable = available
    guard isArmed, let peer = armedPeer else { return }
    if available {
      if !isReceiving { statusMessage = "Ready to receive from \(peer.deviceName)." }
    } else if isReceiving {
      endSession("macOS event access was revoked; receiving stopped.", reason: .accessUnavailable)
    } else {
      statusMessage = "macOS event-posting access is off."
    }
  }

  // Call only from an explicit user action; requesting can show the macOS Events consent prompt.
  @discardableResult func requestEventAccess() -> Bool {
    eventAccessRequestAttempted = true
    _ = eventAdapter.requestPostEventAccess()
    refreshAccessState()
    return eventAccessAvailable
  }

  func arm(ownerID: UUID, for peer: DeviceIdentity) {
    if armedOwnerID == ownerID, samePeer(armedPeer, peer) { return }
    refreshAccessState()
    disarmCurrent()
    armedOwnerID = ownerID
    armedPeer = peer
    statusMessage = eventAccessAvailable
      ? "Ready to receive from \(peer.deviceName)."
      : "macOS event-posting access is off."
  }

  func disarm(ownerID: UUID) {
    guard armedOwnerID == ownerID else { return }
    disarmCurrent()
    statusMessage = "Phone input is off."
  }

  func disarm(for peer: DeviceIdentity) {
    guard isArmed(for: peer) else { return }
    disarmCurrent()
    statusMessage = "Phone input stopped."
  }

  func disarmAll() {
    disarmCurrent()
    statusMessage = "Phone input is off."
  }

  func available(_ channel: any SecuredChannel) {
    let descriptor = channel.descriptor
    guard descriptor.transport == "ble", descriptor.peer.platform == "android" else { return }
    if let old = links[descriptor.transport], old.channel.descriptor != descriptor {
      retired(old.channel.descriptor)
    }
    guard links[descriptor.transport] == nil else { return }
    let link = Link(channel)
    links[descriptor.transport] = link
    let capability = PhoneInputMessage.of(
      1, .integer(PhoneInputMessage.maxTextBytes), .integer(PhoneInputMessage.supportedEvents))
    if let bytes = try? capability.encode() {
      _ = enqueue(bytes, purpose: .capability, on: link)
    }
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard let link = liveLink(descriptor) else { return }
    let wasArmedForPeer = samePeer(armedPeer, descriptor.peer)
    if pendingStart?.descriptor == descriptor { cancelPendingStart(notifyRemote: false) }
    let releaseSucceeded = activeSession?.descriptor == descriptor
      ? endSession("Phone connection ended.", notifyRemote: false) : true
    links[descriptor.transport] = nil
    if wasArmedForPeer {
      armedOwnerID = nil
      automaticOwnerID = nil
      armedPeer = nil
      statusMessage = releaseSucceeded
        ? "Phone connection ended. Turn input on again after reconnecting."
        : "Input access changed; held input could not be released. Reconnect and stop input before continuing."
    }
    link.outgoing.removeAll()
    link.pendingEnd = nil
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard let link = liveLink(descriptor) else { return }
    if link.sending { link.wake = true } else { pump(link) }
  }

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard descriptor.transport == "ble", descriptor.peer.platform == "android",
      let link = liveLink(descriptor)
    else { return .unrecognized }
    let message: PhoneInputMessage
    do {
      guard let decoded = try PhoneInputMessage.decode(bytes) else { return .unrecognized }
      message = decoded
    } catch {
      if activeSession?.descriptor == descriptor {
        endSession("Malformed input stopped the session.", reason: .invalidInput)
      }
      return .discarded
    }

    switch message.kind {
    case 1:
      link.remoteTextBytes = message.number(0)
      link.remoteEvents = message.number(1)
      return .handled
    case 2:
      return receiveStart(message, from: link)
    case 3:
      return .discarded
    case 11:
      if activeSession?.descriptor == descriptor {
        endSession("Invalid session-ended message stopped input.", reason: .invalidInput)
      }
      return .discarded
    default:
      return receiveInput(message, from: link)
    }
  }

  func shutdown() {
    disarmCurrent(notifyRemote: false)
    for link in links.values { link.outgoing.removeAll() }
    links.removeAll()
    statusMessage = "Phone input is off."
  }

  private func receiveStart(_ message: PhoneInputMessage, from link: Link) -> DataHandling {
    refreshAccessState(collectDiagnostics: false)
    let id = message.text(0)
    // A phone's explicit Start is consent for one session; macOS access remains mandatory.
    guard eventAccessAvailable else {
      statusMessage = "macOS event-posting access is off."
      replyToStart(id, result: .unavailable, on: link)
      return .handled
    }
    guard link.remoteTextBytes > 0, link.remoteEvents & 1 != 0 else {
      replyToStart(id, result: .unsupported, on: link)
      return .handled
    }
    guard activeSession == nil, pendingStart == nil, link.pendingEnd == nil else {
      replyToStart(id, result: .busy, on: link)
      return .handled
    }

    let peer = link.channel.descriptor.peer
    if armedOwnerID == nil {
      let ownerID = UUID()
      automaticOwnerID = ownerID
      armedOwnerID = ownerID
      armedPeer = peer
      statusMessage = "Ready to receive from \(peer.deviceName)."
    }
    guard let ownerID = armedOwnerID, samePeer(armedPeer, peer) else {
      replyToStart(id, result: .busy, on: link)
      return .handled
    }

    let start = PendingStart(
      id: UUID(), descriptor: link.channel.descriptor, peer: peer, ownerID: ownerID, messageID: id)
    pendingStart = start
    let response = PhoneInputMessage.of(3, .text(id), .integer(StartResult.accepted.rawValue))
    guard let bytes = try? response.encode(), enqueue(
      bytes, purpose: .startResult(start.id, StartResult.accepted.rawValue), on: link,
      didSend: { [weak self, weak link] in self?.activate(start, messageID: id, link: link) })
    else {
      pendingStart = nil
      releaseAutomaticOwner(start.ownerID)
      statusMessage = "The phone connection is busy. Try again."
      return .discarded
    }
    return .handled
  }

  private func replyToStart(_ id: String, result: StartResult, on link: Link) {
    let response = PhoneInputMessage.of(3, .text(id), .integer(result.rawValue))
    guard let bytes = try? response.encode() else { return }
    _ = enqueue(bytes, purpose: .startResult(UUID(), result.rawValue), on: link)
  }

  private func activate(_ start: PendingStart, messageID: String, link: Link?) {
    guard let link, pendingStart?.id == start.id, liveLink(start.descriptor) === link,
      armedOwnerID == start.ownerID, samePeer(armedPeer, start.peer), eventAdapter.canPostEvents
    else {
      if pendingStart?.id == start.id {
        cancelPendingStart(
          reason: eventAdapter.canPostEvents ? .localStop : .accessUnavailable)
        statusMessage = eventAdapter.canPostEvents
          ? "Input activation was canceled. Turn it on again."
          : "macOS event-posting access is off."
      }
      return
    }
    pendingStart = nil
    activeSession = ActiveSession(id: messageID, descriptor: start.descriptor, ownerID: start.ownerID)
    statusMessage = "Receiving from \(start.peer.deviceName)."
  }

  private func receiveInput(_ message: PhoneInputMessage, from link: Link) -> DataHandling {
    refreshAccessState(collectDiagnostics: false)
    guard var active = activeSession, active.descriptor == link.channel.descriptor,
      active.id == message.text(0), active.ownerID == armedOwnerID,
      samePeer(armedPeer, link.channel.descriptor.peer)
    else { return .discarded }

    let sequence = message.number(1)
    guard sequence > active.lastSequence else {
      endSession("Repeated input stopped the session.", reason: .invalidInput)
      return .discarded
    }

    let requiredEvents: Int64
    switch message.kind {
    case 4: requiredEvents = 1
    case 5: requiredEvents = 2
    case 6, 7, 8: requiredEvents = 4
    default: requiredEvents = 0
    }
    guard requiredEvents == 0 || link.remoteEvents & requiredEvents != 0 else {
      endSession("The phone sent an event it did not advertise.", reason: .invalidInput)
      return .discarded
    }
    if message.kind == 4, Int64(message.text(2).utf8.count) > link.remoteTextBytes {
      endSession("The phone sent text beyond its advertised limit.", reason: .invalidInput)
      return .discarded
    }

    active.lastSequence = sequence
    activeSession = active

    if message.kind == 10 {
      let released = endSession("Phone input stopped.", notifyRemote: false)
      if !released { statusMessage = "Input access changed; held input could not be released." }
      return .handled
    }

    do {
      try eventAdapter.apply(message)
      if !eventAdapter.canPostEvents {
        endSession("Input access changed; receiving stopped.", reason: .accessUnavailable)
        return .discarded
      }
      return .handled
    } catch MacPhoneInputEventError.accessDenied {
      endSession("Input access changed; receiving stopped.", reason: .accessUnavailable)
      return .discarded
    } catch {
      endSession("Unsupported or invalid input stopped the session.", reason: .invalidInput)
      return .discarded
    }
  }

  private func disarmCurrent(notifyRemote: Bool = true) {
    if pendingStart != nil { cancelPendingStart(notifyRemote: notifyRemote) }
    if activeSession != nil {
      endSession("Phone input was turned off.", reason: .localStop, notifyRemote: notifyRemote)
    }
    else if !eventAdapter.releaseAll() {
      statusMessage = "Input access changed; held input could not be released."
    }
    armedOwnerID = nil
    automaticOwnerID = nil
    armedPeer = nil
  }

  private func cancelPendingStart(
    notifyRemote: Bool = true, reason: EndReason = .localStop
  ) {
    guard let start = pendingStart else { return }
    for link in links.values {
      link.outgoing.removeAll { $0.purpose == .startResult(start.id, StartResult.accepted.rawValue) }
    }
    pendingStart = nil
    releaseAutomaticOwner(start.ownerID)
    if notifyRemote, let link = liveLink(start.descriptor) {
      queueSessionEnded(start.messageID, reason: reason, on: link)
    }
  }

  @discardableResult private func endSession(
    _ message: String, reason: EndReason = .localStop, notifyRemote: Bool = true
  ) -> Bool {
    guard activeSession != nil else { return true }
    let session = activeSession!
    let released = eventAdapter.releaseAll()
    activeSession = nil
    statusMessage = released ? message : "Input access changed; held input could not be released."
    releaseAutomaticOwner(session.ownerID)
    if notifyRemote, let link = liveLink(session.descriptor) {
      queueSessionEnded(session.id, reason: released ? reason : .accessUnavailable, on: link)
    }
    return released
  }

  private func enqueue(
    _ bytes: Data, purpose: Outbound.Purpose, on link: Link,
    didSend: (() -> Void)? = nil
  ) -> Bool {
    guard liveLink(link.channel.descriptor) === link, link.outgoing.count < 8 else { return false }
    link.outgoing.append(Outbound(bytes, purpose: purpose, didSend: didSend))
    pump(link)
    return true
  }

  private func pump(_ link: Link) {
    guard liveLink(link.channel.descriptor) === link else { return }
    if link.sending { link.wake = true; return }
    link.sending = true
    Task { [weak self, weak link] in
      guard let self, let link else { return }
      var backpressured = false
      while self.liveLink(link.channel.descriptor) === link {
        guard let first = link.pendingEnd ?? link.outgoing.first else { break }
        do {
          try await link.channel.sendData(first.bytes)
          guard self.liveLink(link.channel.descriptor) === link else { return }
          if link.pendingEnd?.id == first.id { link.pendingEnd = nil }
          else if link.outgoing.first?.id == first.id { link.outgoing.removeFirst() }
          first.didSend?()
        } catch is SessionBackpressure {
          backpressured = true
          break
        } catch {
          self.retired(link.channel.descriptor)
          return
        }
      }
      link.sending = false
      if link.wake && backpressured {
        link.wake = false
        self.pump(link)
      } else {
        link.wake = false
      }
    }
  }

  private func queueSessionEnded(_ id: String, reason: EndReason, on link: Link) {
    guard liveLink(link.channel.descriptor) === link else { return }
    if link.pendingEnd?.purpose == .sessionEnded(id, reason.rawValue) { return }
    guard link.pendingEnd == nil else { return }
    let message = PhoneInputMessage.of(11, .text(id), .integer(reason.rawValue))
    guard let bytes = try? message.encode() else { return }
    link.pendingEnd = Outbound(bytes, purpose: .sessionEnded(id, reason.rawValue))
    pump(link)
  }

  private func liveLink(_ descriptor: ChannelDescriptor) -> Link? {
    guard let link = links[descriptor.transport], link.channel.descriptor == descriptor else { return nil }
    return link
  }

  private func releaseAutomaticOwner(_ ownerID: UUID) {
    guard automaticOwnerID == ownerID else { return }
    automaticOwnerID = nil
    if armedOwnerID == ownerID {
      armedOwnerID = nil
      armedPeer = nil
    }
  }

  private func samePeer(_ lhs: DeviceIdentity?, _ rhs: DeviceIdentity?) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs.deviceId == rhs.deviceId && lhs.fingerprint == rhs.fingerprint
  }
}
