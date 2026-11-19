// SPDX-License-Identifier: GPL-3.0-or-later
// Owns one explicit LAN listening operation, bounded plaintext audio and renewal-aware native capture lifecycle.
import AppKit
import Foundation
import Observation

protocol PrivateListeningCapturing: Actor {
  func prepare() throws
  func activate(alsoPlayThroughMacSpeakers: Bool) async throws
  func setMuting(_ muted: Bool) throws
  func setForwarding(_ enabled: Bool) throws
  func read() throws -> MacAudioTapBatch
  func stop() throws
}
extension MacAudioTapEngine: PrivateListeningCapturing {}

@Observable @MainActor final class MacPrivateListeningModel: FeatureHandler {
  private final class Operation {
    let id = UUID().uuidString.lowercased()
    let descriptor: ChannelDescriptor
    var deadline: Int64
    var ready = false
    var readyAt: Int64?
    var readyMaintenance: Int64 = 0
    let startMaintenance: Int64
    var activating = false
    var receiverState: Int64 = 1
    var lastPeerAt: Int64
    var peerMaintenance: Int64
    var maintenanceTotal: Int64
    var maintenanceActive = false
    var lastSequence: Int64 = 0
    var lastCapturedSequence: Int64 = 0
    var sourceFrames: Int64 = 0
    var statusAt: Int64 = 0
    var appliedForwarding = true
    var resetCapture = false
    init(_ descriptor: ChannelDescriptor, now: Int64, maintenance: Int64) {
      self.descriptor = descriptor
      deadline = now + 5000
      lastPeerAt = now
      peerMaintenance = maintenance
      startMaintenance = maintenance
      maintenanceTotal = maintenance
    }
  }

  private let capture: any PrivateListeningCapturing
  private let now: () -> Int64
  private let automaticallyPump: Bool
  private let preferences: UserDefaults?
  private var channel: (any SecuredChannel)?
  private var operation: Operation?
  private var preparation: Task<Void, Never>?
  private var nativePreparation: Task<Void, Never>?
  private var cleanup: Task<Void, Never>?
  private var activation: Task<Void, Never>?
  private var captureLoop: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  private var sendTask: Task<Void, Never>?
  private var outgoing = [PrivateListeningMessage]()
  private var terminal: PrivateListeningMessage?
  private var audio = [PrivateListeningCapturedPacket]()
  private var generation = 0
  private var sleepObserver: NSObjectProtocol?
  private(set) var receivingEnabled = false
  private(set) var hasCapability = false
  private(set) var capturePrepared = false
  private(set) var status = "Connect LAN and enable receiving on your phone."
  private(set) var state: Int64 = 0
  private(set) var alsoPlayThroughMacSpeakers: Bool
  var pacingChanged: (Bool) -> Void = { _ in }
  var transferReady: () -> Bool = { true }

  init(capture: any PrivateListeningCapturing = MacAudioTapEngine(),
    preferences: UserDefaults? = .standard,
    now: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
    automaticallyPump: Bool = true) {
    self.capture = capture
    self.preferences = preferences
    self.now = now
    self.automaticallyPump = automaticallyPump
    alsoPlayThroughMacSpeakers = preferences?.bool(forKey: "ui.alsoPlayThroughMacSpeakers") ?? false
  }

  var peer: DeviceIdentity? { channel?.descriptor.peer }
  var active: Bool { operation != nil }
  var busy: Bool { preparation != nil || cleanup != nil || active }
  var canPrepare: Bool { !busy }
  var canStart: Bool {
    !busy && terminal == nil && sendTask == nil && capturePrepared && receivingEnabled &&
      hasCapability && channel?.maintenance?.active != true
  }

  func installLifecycle() {
    guard sleepObserver == nil else { return }
    sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.stop(reason: 7, message: "Listening stopped for Mac sleep.") }
      }
  }

  func prepareCapture() {
    guard canPrepare else { return }
    generation += 1
    let token = generation
    status = "Preparing system audio. Allow recording if macOS asks."
    state = 1
    let work = Task { [weak self] in
      guard let self else { return }
      do {
        try Task.checkCancellation()
        try await capture.prepare()
        guard token == generation, !Task.isCancelled else { return }
        capturePrepared = true
        state = 0
        status = "Capture prepared. Start listening when your phone is ready."
      } catch {
        guard token == generation else { return }
        capturePrepared = false
        state = 0
        status = error.localizedDescription
      }
      if token == generation { preparation = nil; nativePreparation = nil }
    }
    preparation = work
    nativePreparation = work
  }

  func start() {
    guard canStart, let channel else { return }
    generation += 1
    let token = generation
    pacingChanged(true)
    state = 1
    status = "Waiting for active transfer…"
    preparation = Task { [weak self] in
      guard let self else { return }
      let deadline = now() + 10000
      do {
        while !transferReady() {
          guard now() < deadline else { throw SessionFailure.expired }
          try await Task.sleep(for: .milliseconds(50))
          guard token == generation, self.channel?.descriptor == channel.descriptor else { return }
        }
        try Task.checkCancellation()
        guard token == generation, self.channel?.descriptor == channel.descriptor, receivingEnabled else { return }
        let current = Operation(channel.descriptor, now: now(),
          maintenance: channel.maintenance?.elapsedMillis ?? 0)
        operation = current
        preparation = nil
        status = "Preparing headphones on \(channel.descriptor.peer.deviceName)…"
        enqueue(.start(streamID: current.id))
        if automaticallyPump { beginCaptureLoop(current); beginWatchdog(current) }
      } catch {
        if token == generation { stop(reason: 7, message: "Preparation timed out or was cancelled.") }
      }
    }
  }

  func setAlsoPlayThroughMacSpeakers(_ enabled: Bool) {
    alsoPlayThroughMacSpeakers = enabled
    preferences?.set(enabled, forKey: "ui.alsoPlayThroughMacSpeakers")
    guard operation?.ready == true else { return }
    let token = generation
    Task { [weak self] in
      guard let self else { return }
      do { try await capture.setMuting(!enabled) }
      catch {
        if token == generation { stop(reason: 6, message: error.localizedDescription) }
      }
    }
  }

  func available(_ channel: any SecuredChannel) {
    guard channel.descriptor.transport == "lan", channel.descriptor.peer.platform == "android" else { return }
    guard self.channel?.descriptor != channel.descriptor else { return }
    if let old = self.channel { retired(old.descriptor) }
    self.channel = channel
    receivingEnabled = false
    hasCapability = false
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard channel?.descriptor == descriptor else { return }
    stop(reason: 3, message: "LAN ended. Start listening again after reconnecting.", notify: false)
    channel = nil
    receivingEnabled = false
    hasCapability = false
    outgoing.removeAll()
    terminal = nil
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard channel?.descriptor == descriptor else { return }
    reflectMaintenance()
    pump()
  }

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard channel?.descriptor == descriptor else { return .unrecognized }
    let message: PrivateListeningMessage
    do {
      guard let decoded = try PrivateListeningMessage.decode(bytes) else { return .unrecognized }
      message = decoded
    } catch {
      stop(reason: 5, message: "Invalid listening message.")
      return .discarded
    }
    if message.kind == 0 {
      hasCapability = true
      receivingEnabled = message.flag(4)
      if !receivingEnabled && (active || preparation != nil) { stop(message: "Receiving was disabled on the phone.") }
      return .handled
    }
    guard let current = operation, current.descriptor == descriptor, message.text(0) == current.id else {
      return .discarded
    }
    switch message.kind {
    case 2:
      guard !current.ready, !current.activating else { return .discarded }
      let maintenance = channel?.maintenance?.elapsedMillis ?? 0
      guard now() - max(0, maintenance - current.startMaintenance) < current.deadline else {
        stop(reason: 7, message: "The phone did not become ready in time.")
        return .discarded
      }
      guard message.number(1) == 0 else {
        let code = Int(message.number(1))
        stop(message: Self.startResults[code])
        return .handled
      }
      current.activating = true
      let work = Task { [weak self] in
        guard let self else { return }
        do {
          try Task.checkCancellation()
          try await capture.activate(alsoPlayThroughMacSpeakers: alsoPlayThroughMacSpeakers)
          guard operation === current, channel?.descriptor == descriptor else {
            try await capture.stop()
            return
          }
          current.ready = true
          current.readyAt = now()
          current.readyMaintenance = channel?.maintenance?.elapsedMillis ?? 0
          current.activating = false
          current.lastPeerAt = now()
          current.peerMaintenance = channel?.maintenance?.elapsedMillis ?? 0
          preparation = nil
          activation = nil
          state = 2
          status = "Listening on \(descriptor.peer.deviceName)."
        } catch {
          if operation === current { stop(reason: 6, message: error.localizedDescription) }
        }
      }
      preparation = work
      activation = work
    case 4:
      stop(reason: message.number(1), message: "Listening ended on your phone.", notify: false)
    case 5:
      guard message.number(1) == 1 else { return .discarded }
      let wasFocusPaused = current.receiverState == 3
      current.receiverState = message.number(2)
      if wasFocusPaused && current.receiverState != 3 && current.lastSequence == 0 {
        current.readyAt = now()
        current.readyMaintenance = channel?.maintenance?.elapsedMillis ?? 0
      }
      current.lastPeerAt = now()
      current.peerMaintenance = channel?.maintenance?.elapsedMillis ?? 0
      if current.receiverState == 0 {
        stop(message: "Listening ended on your phone.", notify: false)
      } else { reflectMaintenance() }
    default:
      return .discarded
    }
    return .handled
  }

  func drain(_ descriptor: ChannelDescriptor) async {
    guard channel?.descriptor == descriptor else { return }
    stop(reason: 3, message: "The phone closed LAN.", notify: false)
  }

  func stop(reason: Int64 = 0, message: String = "Listening stopped. Mac output restored.", notify: Bool = true) {
    let old = operation
    generation += 1
    preparation?.cancel(); preparation = nil
    captureLoop?.cancel(); captureLoop = nil
    watchdog?.cancel(); watchdog = nil
    sendTask?.cancel(); sendTask = nil
    operation = nil
    audio.removeAll()
    outgoing.removeAll()
    terminal = nil
    capturePrepared = false
    state = 0
    status = message
    pacingChanged(false)
    if notify, let old, channel?.descriptor == old.descriptor {
      terminal = PrivateListeningMessage(kind: 4, fields: [.text(old.id), .integer(reason)])
      pump()
    }
    if cleanup == nil {
      let pendingActivation = activation
      let pendingPreparation = nativePreparation
      activation = nil
      nativePreparation = nil
      cleanup = Task { [weak self] in
        guard let self else { return }
        await pendingPreparation?.value
        await pendingActivation?.value
        do { try await capture.stop() }
        catch { status = "Listening ended, but audio cleanup failed: \(error.localizedDescription)" }
        cleanup = nil
      }
    }
  }

  func shutdown() {
    if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    sleepObserver = nil
    stop(notify: false)
    channel = nil
  }

  func reflectMaintenance() {
    guard let current = operation, let channel else { return }
    let total = channel.maintenance?.elapsedMillis ?? 0
    let maintenance = channel.maintenance?.active == true
    let transitioned = maintenance != current.maintenanceActive
    let completed = !maintenance && total > current.maintenanceTotal
    if transitioned || completed {
      // Pre-seal cancellation prevents an admission waiter from submitting old audio after maintenance.
      sendTask?.cancel()
      if completed { current.resetCapture = true }
      audio.removeAll()
      outgoing.removeAll { $0.kind == 5 }
      current.maintenanceTotal = total
      current.maintenanceActive = maintenance
    }
    if current.ready {
      state = maintenance ? 4 : current.receiverState == 3 ? 3 : current.receiverState == 5 ? 5 : 2
      status = state == 4 ? "Renewing secure LAN…" : state == 3 ? "Phone audio focus interrupted." :
        state == 5 ? "Buffering current audio…" : "Listening on \(current.descriptor.peer.deviceName)."
    }
  }

  func tick() async {
    guard let current = operation, let channel else { return }
    reflectMaintenance()
    guard operation === current else { return }
    guard checkDeadlines(current) else { return }
    guard current.ready else { pump(); return }
    do {
      let forward = !current.maintenanceActive && current.receiverState != 3
      if current.resetCapture {
        try await capture.setForwarding(false)
        guard operation === current else { return }
        current.appliedForwarding = false
        current.resetCapture = false
      }
      if current.appliedForwarding != forward {
        try await capture.setForwarding(forward)
        guard operation === current else { return }
        current.appliedForwarding = forward
        audio.removeAll()
      }
      let batch = try await capture.read()
      guard operation === current else { return }
      current.sourceFrames = max(current.sourceFrames, batch.sourceFrames)
      if forward {
        for packet in batch.packets where packet.sequence > current.lastCapturedSequence {
          current.lastCapturedSequence = packet.sequence
          audio.append(packet)
        }
        if audio.count > 3 { audio.removeFirst(audio.count - 3) } // One additional packet may be owned by a send.
      }
      if !current.maintenanceActive && now() - current.statusAt >= 1000 {
        current.statusAt = now()
        enqueue(PrivateListeningMessage(kind: 5, fields: [.text(current.id), .integer(0),
          .integer(state), .integer(current.lastSequence), .integer(current.sourceFrames),
          .integer(min(48000, batch.queuedFrames + Int64(audio.count * 960))), .integer(0)]))
      }
      pump()
    } catch {
      if operation === current { stop(reason: 6, message: error.localizedDescription) }
    }
  }

  private func beginCaptureLoop(_ current: Operation) {
    captureLoop = Task { [weak self] in
      guard let self else { return }
      while operation === current && !Task.isCancelled {
        await tick()
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
      }
    }
  }

  private func beginWatchdog(_ current: Operation) {
    watchdog = Task { [weak self] in
      guard let self else { return }
      while operation === current && !Task.isCancelled {
        reflectMaintenance()
        guard checkDeadlines(current) else { return }
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
      }
    }
  }

  private func checkDeadlines(_ current: Operation) -> Bool {
    guard operation === current else { return false }
    guard channel?.maintenance?.active != true else { return true }
    let maintenance = channel?.maintenance?.elapsedMillis ?? 0
    if !current.ready && now() - max(0, maintenance - current.startMaintenance) >= current.deadline {
      stop(reason: 7, message: "The phone did not become ready in time.")
      return false
    }
    if current.ready && now() - current.lastPeerAt - max(0, maintenance - current.peerMaintenance) >= 10000 {
      stop(reason: 3, message: "The phone stopped responding. Mac output restored.")
      return false
    }
    if current.ready, current.lastSequence == 0, current.receiverState != 3,
      let readyAt = current.readyAt, now() - readyAt - max(0, maintenance - current.readyMaintenance) >= 5000 {
      stop(reason: 6, message: "System audio has not produced a complete packet. Check recording access and the source.")
      return false
    }
    return true
  }

  private func enqueue(_ message: PrivateListeningMessage) {
    if message.kind == 5 { outgoing.removeAll { $0.kind == 5 } }
    guard outgoing.count < 8 else { return }
    outgoing.append(message)
    pump()
  }

  private func pump() {
    guard sendTask == nil, let channel, channel.maintenance?.active != true,
      terminal != nil || !outgoing.isEmpty || !audio.isEmpty else { return }
    let token = generation
    sendTask = Task { [weak self] in
      guard let self else { return }
      defer { if token == generation { sendTask = nil } }
      while token == generation, self.channel?.descriptor == channel.descriptor, !Task.isCancelled {
        let message: PrivateListeningMessage
        if let boundary = terminal { message = boundary; terminal = nil }
        else if let first = outgoing.first { message = first; outgoing.removeFirst() }
        else if let current = operation, current.ready, state != 3, state != 4, !audio.isEmpty {
          let packet = audio.removeFirst()
          do { message = try .audio(streamID: current.id, sequence: packet.sequence, pcm: packet.pcm) }
          catch { stop(reason: 5, message: "Invalid captured audio."); return }
        } else { return }
        do {
          try Task.checkCancellation()
          try await channel.sendData(message.encode())
          guard token == generation else { return }
          if message.kind == 3 { operation?.lastSequence = message.number(1) }
        } catch is SessionBackpressure {
          if token == generation {
            if message.kind == 4 { terminal = message }
            else if message.kind != 3 {
              if outgoing.count == 8 { outgoing.removeLast() }
              outgoing.insert(message, at: 0)
            }
          }
          return
        } catch is CancellationError {
          if token == generation {
            if message.kind == 4 { terminal = message }
            else if message.kind != 3 && message.kind != 5 {
              if outgoing.count == 8 { outgoing.removeLast() }
              outgoing.insert(message, at: 0)
            }
          }
          return
        }
        catch {
          if token == generation { stop(reason: 3, message: error.localizedDescription, notify: false) }
          return
        }
      }
    }
  }

  private static let startResults = [
    "Phone headphones ready.", "Enable receiving on your phone.", "Phone audio is already busy.",
    "Phone audio format is unsupported.", "Open aniCe on your phone, then retry.",
    "Phone audio focus was denied.", "Connect or confirm headphones on your phone.",
    "Phone notification setup failed.", "Phone audio preparation failed.", "Phone preparation timed out.",
  ]
}
