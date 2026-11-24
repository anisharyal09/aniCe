// SPDX-License-Identifier: GPL-3.0-or-later
// Owns credential-scoped reverse receiving consent, one authenticated stream and explicit local Stop.
import AppKit
import Foundation
import Observation

@Observable @MainActor final class MacPhoneAudioModel: FeatureHandler {
  private final class Operation {
    let id: String
    let descriptor: ChannelDescriptor
    let startedAt: Int64
    let startMaintenance: Int64
    var lastPacketAt: Int64
    var packetMaintenance: Int64
    var maintenanceTotal: Int64
    var maintenanceActive = false
    var refreshingOutput = false
    var ready = false
    init(id: String, descriptor: ChannelDescriptor, now: Int64, maintenance: Int64) {
      self.id = id
      self.descriptor = descriptor
      startedAt = now
      startMaintenance = maintenance
      lastPacketAt = now
      packetMaintenance = maintenance
      maintenanceTotal = maintenance
    }
  }

  private let receiver: PhoneAudioReceiver
  private let preferences: UserDefaults?
  private let now: () -> Int64
  private let automaticTicks: Bool
  private let localFingerprint: () throws -> String
  private var channel: (any SecuredChannel)?
  private var operation: Operation?
  private var localValue: String?
  private var loadTask: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  private var preparation: Task<Void, Never>?
  private var cleanup: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var sendTask: Task<Void, Never>?
  private var outgoing = [PhoneAudioMessage]()
  private var terminal: PhoneAudioMessage?
  private var generation = 0
  private var linkGeneration = 0
  private var retiredIDs = Set<String>()
  private var exhaustedIDs = false
  private var sleepObserver: NSObjectProtocol?
  private(set) var receivingEnabled = false
  private(set) var localReady = false
  private(set) var state: Int64 = 0
  private(set) var status = "Connect your trusted phone over LAN."
  private(set) var acceptedPackets = 0
  private(set) var gapPackets = 0
  private(set) var outputResyncs = 0
  private(set) var queuedOutputFrames = 0
  var forwardActive: () -> Bool = { false }
  var onActiveChanged: (Bool) -> Void = { _ in }

  init(receiver: PhoneAudioReceiver = PhoneAudioReceiver(),
    preferences: UserDefaults? = .standard,
    localFingerprint: @escaping () throws -> String = { "" },
    now: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
    automaticTicks: Bool = true) {
    self.receiver = receiver
    self.preferences = preferences
    self.localFingerprint = localFingerprint
    self.now = now
    self.automaticTicks = automaticTicks
  }

  var peer: DeviceIdentity? { channel?.descriptor.peer }
  var active: Bool { operation != nil }
  var busy: Bool { active || cleanup != nil }
  var canToggle: Bool { channel != nil && localReady }
  var canReceive: Bool { canToggle && !forwardActive() }

  func installLifecycle() {
    guard sleepObserver == nil else { return }
    sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.stop(reason: 7, message: "Phone audio stopped for Mac sleep.") }
      }
  }

  func available(_ channel: any SecuredChannel) {
    guard channel.descriptor.transport == "lan", channel.descriptor.peer.platform == "android" else { return }
    guard !matches(channel.descriptor) else { return }
    if let old = self.channel { retired(old.descriptor) }
    self.channel = channel
    operation = nil
    receivingEnabled = false
    localReady = false
    localValue = nil
    acceptedPackets = 0
    gapPackets = 0
    outputResyncs = 0
    queuedOutputFrames = 0
    retiredIDs.removeAll()
    exhaustedIDs = false
    status = "Checking receiving consent…"
    let descriptor = channel.descriptor
    linkGeneration += 1
    let token = linkGeneration
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let local = try self.localFingerprint()
        guard token == self.linkGeneration, self.matches(descriptor) else { return }
        guard !local.isEmpty else {
          self.status = "Local identity could not be verified."
          return
        }
        self.localValue = local
        self.receivingEnabled = self.preferences?.bool(forKey: Self.key(local, descriptor.peer)) ?? false
        self.localReady = true
        self.status = self.receivingEnabled ? "Ready to receive phone audio."
          : "Allow audio from this phone to receive it."
        self.sendCapability()
      } catch {
        guard token == self.linkGeneration else { return }
        self.status = "Local identity could not be verified."
      }
    }
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard matches(descriptor) else { return }
    channel = nil
    linkGeneration += 1
    stop(reason: 3, message: "LAN ended. Start phone audio again after reconnecting.", notify: false)
    localReady = false
    localValue = nil
    receivingEnabled = false
    loadTask?.cancel(); loadTask = nil
    outgoing.removeAll()
    terminal = nil
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard matches(descriptor) else { return }
    reflectMaintenance()
    pump()
  }

  /// Consent is default-off, bound to this Mac identity and the full phone credential, and never implied by Start.
  func setReceiving(_ enabled: Bool) {
    guard let channel, localReady, let local = localValue else { return }
    if enabled && forwardActive() {
      status = "Stop listening to this phone before receiving its audio."
      return
    }
    preferences?.set(enabled, forKey: Self.key(local, channel.descriptor.peer))
    receivingEnabled = enabled
    if !enabled && busy {
      stop(message: "Receiving was disabled on this Mac.")
    } else {
      status = enabled ? "Ready to receive phone audio." : "Allow audio from this phone to receive it."
    }
    sendCapability()
  }

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard matches(descriptor) else { return .unrecognized }
    let message: PhoneAudioMessage
    do {
      guard let decoded = try PhoneAudioMessage.decode(bytes) else { return .unrecognized }
      message = decoded
    } catch {
      stop(reason: 5, message: "Invalid phone audio message.")
      return .discarded
    }
    let validated: PrivateListeningMessage
    do { validated = try message.validated() } catch {
      stop(reason: 5, message: "Invalid phone audio message.")
      return .discarded
    }
    switch message.kind {
    case 1:
      return await receiveStart(validated, on: descriptor)
    case 3:
      return await receiveAudio(validated, on: descriptor)
    case 4:
      guard let current = operation, validated.text(0) == current.id else { return .discarded }
      stop(reason: validated.number(1), message: "Phone audio ended on the phone.", notify: false)
      return .handled
    default:
      return .discarded
    }
  }

  func drain(_ descriptor: ChannelDescriptor) async {
    guard matches(descriptor) else { return }
    stop(reason: 3, message: "The phone closed LAN.", notify: false)
  }

  func stop(reason: Int64 = 0, message: String = "Phone audio stopped.", notify: Bool = true) {
    let old = operation
    generation += 1
    operation = nil
    watchdog?.cancel(); watchdog = nil
    preparation?.cancel(); preparation = nil
    refreshTask?.cancel(); refreshTask = nil
    sendTask?.cancel(); sendTask = nil
    outgoing.removeAll()
    terminal = nil
    state = 0
    status = message
    queuedOutputFrames = 0
    // Close admission before awaiting native prepare/Stop. Cleanup keeps the other direction excluded.
    receiver.invalidate()
    if cleanup == nil {
      cleanup = Task { [weak self] in
        guard let self else { return }
        await receiver.stop()
        cleanup = nil
        if operation == nil { onActiveChanged(false) }
      }
    }
    if notify, let old, matches(old.descriptor) {
      terminal = PhoneAudioMessage(kind: 4, fields: [.text(old.id), .integer(reason)])
      pump()
    }
    if localReady { sendCapability() }
  }

  func shutdown() {
    if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    sleepObserver = nil
    channel = nil
    linkGeneration += 1
    loadTask?.cancel(); loadTask = nil
    stop(notify: false)
    receivingEnabled = false
    localReady = false
    localValue = nil
  }

  func invalidate() {
    channel = nil
    linkGeneration += 1
    loadTask?.cancel(); loadTask = nil
    stop(reason: 7, message: "Device trust or local identity changed.", notify: false)
    receivingEnabled = false
    localReady = false
    localValue = nil
  }

  private func receiveStart(_ message: PrivateListeningMessage,
    on descriptor: ChannelDescriptor) async -> DataHandling {
    let id = message.text(0)
    if let current = operation {
      if current.id == id {
        if current.ready { reply(id, 0) }
      } else { reply(id, 2) }
      return .handled
    }
    guard !busy, !retiredIDs.contains(id), !exhaustedIDs else { reply(id, 2); return .handled }
    // Refuse new operations on replay-set exhaustion rather than forgetting retired UUIDs.
    retiredIDs.insert(id)
    if retiredIDs.count >= 256 { exhaustedIDs = true }
    guard receivingEnabled, localReady else {
      reply(id, 1)
      status = "Allow audio from this phone first."
      return .handled
    }
    if forwardActive() {
      reply(id, 2)
      status = "Stop listening to this phone before receiving its audio."
      return .handled
    }
    let current = Operation(id: id, descriptor: descriptor, now: now(),
      maintenance: channel?.maintenance?.elapsedMillis ?? 0)
    operation = current
    acceptedPackets = 0
    gapPackets = 0
    outputResyncs = 0
    queuedOutputFrames = 0
    state = 1
    status = "Preparing Mac output — it may be audible to others."
    onActiveChanged(true)
    beginWatchdog()
    let token = generation
    let work = Task { [weak self] in
      guard let self else { return }
      guard operation === current, token == generation, matches(descriptor), !Task.isCancelled else { return }
      do {
        let bound = try await receiver.bind(message, on: descriptor)
        guard operation === current, token == generation, matches(descriptor), !Task.isCancelled else { return }
        guard bound else { throw MacPhoneAudioOutputError.unavailable }
        let total = channel?.maintenance?.elapsedMillis ?? 0
        guard now() - current.startedAt - max(0, total - current.startMaintenance) < 5000 else {
          stop(reason: 6, message: "Mac audio output preparation timed out.", notify: false)
          reply(id, 9)
          return
        }
        guard receivingEnabled, localReady, !forwardActive() else {
          stop(message: "Phone audio receiving is no longer available.")
          return
        }
        current.ready = true
        current.lastPacketAt = now()
        current.packetMaintenance = total
        state = channel?.maintenance?.active == true ? 4 : 2
        status = state == 4 ? "Renewing secure LAN…"
          : "Receiving phone audio on this Mac — output may not be private."
        preparation = nil
        reply(id, 0)
      } catch {
        guard operation === current, token == generation else { return }
        stop(reason: 6, message: "Mac audio output could not start.", notify: false)
        reply(id, 6)
      }
    }
    preparation = work
    await work.value
    return .handled
  }

  private func receiveAudio(_ message: PrivateListeningMessage,
    on descriptor: ChannelDescriptor) async -> DataHandling {
    reflectMaintenance()
    guard let current = operation, current.ready, message.text(0) == current.id,
      !current.maintenanceActive, !current.refreshingOutput else { return .discarded }
    let reception = await receiver.receive(message, on: descriptor)
    guard operation === current, matches(descriptor) else { return .discarded }
    switch reception {
    case .accepted:
      acceptedPackets = receiver.acceptedPackets
      gapPackets = receiver.gapPackets
      current.lastPacketAt = now()
      current.packetMaintenance = channel?.maintenance?.elapsedMillis ?? 0
      let diagnostics = await receiver.diagnostics()
      guard operation === current, matches(descriptor) else { return .discarded }
      outputResyncs = diagnostics.resyncs
      queuedOutputFrames = diagnostics.queuedFrames
      return .handled
    case .outputUnavailable:
      stop(reason: 6, message: "Mac audio output stopped. Start phone audio again.", notify: true)
      return .handled
    case .unbound, .duplicate, .staleStream:
      return .discarded
    }
  }

  private func beginWatchdog() {
    guard automaticTicks else { return }
    watchdog?.cancel()
    watchdog = Task { [weak self] in
      guard let self else { return }
      while self.operation != nil, !Task.isCancelled {
        self.tick()
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
      }
    }
  }

  func tick() {
    guard let current = operation else { return }
    reflectMaintenance()
    guard operation === current, channel?.maintenance?.active != true else { return }
    let total = channel?.maintenance?.elapsedMillis ?? 0
    if !current.ready {
      if now() - current.startedAt - max(0, total - current.startMaintenance) >= 5000 {
        stop(reason: 6, message: "Mac audio output preparation timed out.", notify: false)
        reply(current.id, 9)
      }
    } else if now() - current.lastPacketAt - max(0, total - current.packetMaintenance) >= 10000 {
      stop(reason: 3, message: "The phone stopped sending audio.")
    }
    pump()
  }

  private func reflectMaintenance() {
    guard let current = operation, let channel else { return }
    let total = channel.maintenance?.elapsedMillis ?? 0
    let active = channel.maintenance?.active == true
    let completed = !active && total > current.maintenanceTotal
    guard active != current.maintenanceActive || completed else { return }
    current.maintenanceActive = active
    current.maintenanceTotal = total
    state = active ? 4 : (current.ready ? 2 : 1)
    status = active ? "Renewing secure LAN…" : (current.ready
      ? "Receiving phone audio on this Mac — output may not be private."
      : "Preparing Mac output — it may be audible to others.")
    guard current.ready else { return }
    current.refreshingOutput = true
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      guard let self else { return }
      let available = await receiver.resumeCurrentAudio()
      guard operation === current, !Task.isCancelled else { return }
      current.refreshingOutput = false
      refreshTask = nil
      queuedOutputFrames = 0
      if !available { stop(reason: 6, message: "Mac audio output ended during LAN renewal.") }
    }
  }

  private func reply(_ id: String, _ code: Int64) {
    enqueue(PhoneAudioMessage(kind: 2, fields: [.text(id), .integer(code)]))
  }

  private func sendCapability() {
    guard channel != nil else { return }
    enqueue(PhoneAudioMessage(kind: 0, fields: [.integer(48000), .integer(2), .integer(16),
      .integer(960), .bool(receivingEnabled)]))
  }

  private func enqueue(_ message: PhoneAudioMessage) {
    if message.kind == 0 { outgoing.removeAll { $0.kind == 0 } }
    if message.kind == 2 { outgoing.removeAll { $0.kind == 2 && $0.fields[0] == message.fields[0] } }
    if outgoing.count == 8 {
      let currentResult = operation.map { message.kind == 2 && message.fields[0] == .text($0.id) } ?? false
      guard message.kind == 0 || currentResult else { return }
      outgoing.removeLast()
    }
    outgoing.append(message)
    pump()
  }

  private func pump() {
    guard sendTask == nil, let channel, channel.maintenance?.active != true,
      terminal != nil || !outgoing.isEmpty else { return }
    let token = generation
    sendTask = Task { [weak self] in
      guard let self else { return }
      defer { if token == self.generation { self.sendTask = nil } }
      while token == self.generation, self.matches(channel.descriptor),
        channel.maintenance?.active != true, !Task.isCancelled {
        let message: PhoneAudioMessage
        if let boundary = self.terminal { message = boundary; self.terminal = nil }
        else if !self.outgoing.isEmpty { message = self.outgoing.removeFirst() }
        else { return }
        do {
          try await channel.sendData(message.encode())
        } catch is SessionBackpressure {
          if token == self.generation {
            self.retain(message)
          }
          return
        } catch is CancellationError {
          if token == self.generation {
            self.retain(message)
          }
          return
        } catch {
          if token == self.generation {
            self.retired(channel.descriptor)
            self.status = "Phone audio DATA could not be sent. Reconnect LAN, then retry."
          }
          return
        }
      }
    }
  }

  private func retain(_ message: PhoneAudioMessage) {
    if message.kind == 4 { terminal = message }
    else {
      // A newer consent capability supersedes a backpressured snapshot.
      if message.kind == 0 && outgoing.contains(where: { $0.kind == 0 }) { return }
      if outgoing.count == 8 { outgoing.removeLast() }
      outgoing.insert(message, at: 0)
    }
  }

  private func matches(_ descriptor: ChannelDescriptor) -> Bool {
    guard let current = channel?.descriptor else { return false }
    return current == descriptor && current.peer.publicKey == descriptor.peer.publicKey &&
      current.peer.algorithm == descriptor.peer.algorithm &&
      current.peer.identitySchemaVersion == descriptor.peer.identitySchemaVersion &&
      current.peer.platform == descriptor.peer.platform
  }

  private static func key(_ local: String, _ peer: DeviceIdentity) -> String {
    "phoneAudio.receive:\(local):\(peer.deviceId):\(peer.fingerprint):\(peer.publicKey)"
  }
}
