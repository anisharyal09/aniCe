// SPDX-License-Identifier: GPL-3.0-or-later
// Hands-Free client for the Gate 1 probe.
//
// The Mac is the Hands-Free (HF) unit and the phone is the Audio Gateway (AG).
// Establishing the Mac's *own* Hands-Free service record proves nothing about
// audio: the probe connects to the phone's AG service (0x111F), uses the
// native Hands-Free implementation for its Service Level Connection, and then waits for the
// operator or an explicit flag to place or answer a call.
import Foundation
import IOBluetooth

enum HFPService {
  /// Hands-Free unit service (the role the Mac plays).
  static let handsFree: BluetoothSDPUUID16 = 0x111E
  /// Audio Gateway service on the phone.
  static let audioGateway: BluetoothSDPUUID16 = 0x111F
}

enum HFPConnectionState: String {
  case idle
  case openingAGChannel
  case serviceLevelConnection
  case callActive
  case closed
}

@MainActor
final class HFPProbe: NSObject, IOBluetoothHandsFreeDeviceDelegate, IOBluetoothDeviceAsyncCallbacks {
  private let log: ProbeLog
  private let targetAddress: [UInt8]
  private(set) var device: IOBluetoothDevice?
  private var native: IOBluetoothHandsFreeDevice?
  private(set) var state: HFPConnectionState = .idle
  private(set) var negotiatedFeatures: UInt32?
  private(set) var agServiceChannelID: UInt8?
  private var sdpQueryStatus: IOReturn = kIOReturnError
  private var sdpQueryFinished = false
  private var connectionStatus: Int32?
  private var scoStatus: Int32?
  var callActive: Bool { native?.indicator(IOBluetoothHandsFreeIndicatorCall) == 1 }
  var ringing: Bool { native?.indicator(IOBluetoothHandsFreeIndicatorCallSetup) == 1 }
  var audioConnected: Bool { native?.isSCOConnected() == true }

  init(log: ProbeLog, address: [UInt8]) {
    self.log = log
    self.targetAddress = address
    super.init()
  }

  /// System-paired Classic devices, deduplicated by address. macOS can return
  /// the same device more than once (one entry per cached record), and a
  /// duplicate must not read as two devices.
  static func pairedDevices() -> [IOBluetoothDevice] {
    let all = IOBluetoothDevice.pairedDevices()?.compactMap { $0 as? IOBluetoothDevice } ?? []
    var seen: Set<String> = []
    var unique: [IOBluetoothDevice] = []
    for device in all {
      let key = device.addressString ?? "unknown-\(device.hash)"
      guard seen.insert(key).inserted else { continue }
      unique.append(device)
    }
    return unique
  }

  // MARK: - Device selection

  func selectDevice() throws -> IOBluetoothDevice {
    let text = ClassicAddress.canonical(targetAddress)
    log.step("Selecting system-paired Classic device " + text)
    let paired = Self.pairedDevices()
    log.result("System-paired Classic devices: " + (paired.isEmpty ? "none" : "\(paired.count)"))
    for candidate in paired {
      let name = candidate.name ?? "(unnamed)"
      let address = candidate.addressString ?? "(no address)"
      log.detail("paired", name + " | " + address)
    }
    let match = paired.first {
      $0.addressString.flatMap(ClassicAddress.parse).map(ClassicAddress.canonical) == text
    }
    guard let match else {
      throw ProbeFailure.device(
        "no system-paired Classic device has address \(text). Pair the phone in "
          + "System Settings → Bluetooth first; display names are never used for selection.")
    }
    device = match
    log.result("Selected \(match.name ?? "(unnamed)") — paired=\(match.isPaired()) connected=\(match.isConnected())")
    guard match.isPaired() else {
      throw ProbeFailure.device("device \(text) is not paired; the probe requires OS pairing")
    }
    return match
  }

  // MARK: - SDP

  /// Fresh asynchronous SDP query, then the AG record is read from the
  /// device's SDP cache. A failed query is fatal: the probe never reuses a
  /// channel number remembered from another run.
  func queryAudioGatewayService() async throws -> UInt8 {
    guard let device else { throw ProbeFailure.device("select a device first") }
    log.step("Running fresh asynchronous SDP query for the Audio Gateway (0x111F)")
    if !device.isConnected() {
      // SDP runs over the baseband link. A paired device that is not currently
      // connected reports "connected=false" and can leave the query without a
      // completion callback, so raise the link first.
      log.result("Device is paired but not connected; raising the Classic link for the query")
      let status = device.openConnection()
      log.detail("openConnection", status.fourCCDescription)
      let connected = await waitUntil(timeout: 10) { device.isConnected() }
      log.detail("connected", connected ? "yes" : "no")
      if !connected { log.result("Link did not come up; the SDP query may time out.") }
    }
    for attempt in 1...2 {
      if try await runSDPQuery(on: device, attempt: attempt) { break }
      guard attempt == 1 else {
        throw ProbeFailure.handsFree(
          "SDP query produced no completion callback twice; no cached channel is used")
      }
      log.result("Retrying once after raising the link")
      _ = device.openConnection()
      _ = await waitUntil(timeout: 5) { device.isConnected() }
    }
    return try extractAudioGatewayChannel(from: device)
  }

  /// Runs one query attempt. Returns true when the delegate callback arrived,
  /// false when it did not (as opposed to a reported failure, which throws).
  private func runSDPQuery(on device: IOBluetoothDevice, attempt: Int) async throws -> Bool {
    sdpQueryFinished = false
    sdpQueryStatus = kIOReturnError
    let started = device.performSDPQuery(self)
    log.detail("performSDPQuery (attempt \(attempt))", started.fourCCDescription)
    guard started == kIOReturnSuccess else {
      throw ProbeFailure.handsFree("SDP query could not be started (\(started.fourCCDescription))")
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !sdpQueryFinished && ContinuousClock.now < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    if !sdpQueryFinished {
      log.result("No sdpQueryComplete callback within 15 seconds (attempt \(attempt)).")
      return false
    }
    guard sdpQueryStatus == kIOReturnSuccess else {
      log.result("sdpQueryComplete reported failure: " + sdpQueryStatus.fourCCDescription)
      return false
    }
    return true
  }

  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while ContinuousClock.now < deadline {
      if state == .closed || Task.isCancelled { return false }
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
  }

  private func extractAudioGatewayChannel(from device: IOBluetoothDevice) throws -> UInt8 {
    let hint = IOBluetoothSDPUUID(uuid16: HFPService.audioGateway)
    guard let record = device.getServiceRecord(for: hint) else {
      log.result("No Audio Gateway (0x111F) record on this device.")
      log.result(
        "Either the phone does not offer Classic call audio to this Mac, or the SDP cache is "
          + "incomplete. The probe does not invent a channel.")
      throw ProbeFailure.handsFree("phone exposes no Audio Gateway service record")
    }
    var identifier: BluetoothRFCOMMChannelID = 0
    let status = record.getRFCOMMChannelID(&identifier)
    guard status == kIOReturnSuccess else {
      throw ProbeFailure.handsFree("AG role record has no RFCOMM channel (\(status.fourCCDescription))")
    }
    guard (0x01...0x1E).contains(identifier) else {
      throw ProbeFailure.handsFree(
        "AG RFCOMM channel ID \(identifier) is outside the usable range 1…30")
    }
    log.result("Audio Gateway RFCOMM channel: \(identifier)")
    agServiceChannelID = identifier
    return identifier
  }

  // Native HFP owns AT transactions, indicator indexing and supported features.
  // Do not open a second raw RFCOMM channel alongside it.
  func openConnection(to device: IOBluetoothDevice, channelID: UInt8) async throws {
    log.step("Connecting native Hands-Free client (SDP AG channel \(channelID))")
    guard let client = IOBluetoothHandsFreeDevice(device: device, delegate: self) else {
      throw ProbeFailure.handsFree("native Hands-Free client unavailable")
    }
    native = client
    connectionStatus = nil
    state = .openingAGChannel
    log.detail("native HF supported features", String(format: "0x%04X", client.supportedFeatures))
    client.connect()
  }

  func establishServiceLevelConnection() async throws {
    let completed = await waitUntil(timeout: 20) { self.connectionStatus != nil }
    guard completed, connectionStatus == 0, let native, native.isConnected else {
      throw ProbeFailure.handsFree("native SLC did not complete successfully: \(connectionStatus.map(String.init) ?? "timeout")")
    }
    state = .serviceLevelConnection
    negotiatedFeatures = native.deviceSupportedFeatures
    log.result("Native service-level connection confirmed")
    log.detail("AG supported features", String(format: "0x%04X", native.deviceSupportedFeatures))
    let codec = IOBluetoothHandsFreeAudioGatewayFeatures.codecNegotiation.rawValue
    log.detail("AG codec negotiation support", native.deviceSupportedFeatures & codec != 0 ? "yes; negotiated codec unverified" : "no")
  }

  func establishAudio(phoneInitiatedOnly: Bool = false) async -> Bool {
    guard let native, native.isConnected, callActive else { return false }
    scoStatus = nil
    if phoneInitiatedOnly {
      log.step("Passive phone-initiated SCO test (30-second routing window)")
      log.result("The probe makes no explicit Mac audio-transfer request during this window.")
    } else {
      log.step("Requesting native transferAudioToComputer (30-second routing window)")
      native.transferAudioToComputer()
    }
    log.result("On the phone, select this Mac in the in-call Bluetooth audio picker now.")
    // A failed local request does not exclude a subsequent phone-initiated SCO
    // connection. Keep the native owner alive for the bounded routing window.
    _ = await waitUntil(timeout: 30) {
      self.audioConnected || !native.isConnected || !self.callActive
    }
    let connected = state != .closed && audioConnected && callActive
    log.result("SCO connected=\(connected); callback status=\(scoStatus.map { $0.fourCCDescription } ?? "none")")
    return connected
  }

  func releaseAudio() async -> Bool {
    guard let native else { return true }
    native.transferAudioToPhone()
    native.disconnectSCO()
    let released = await waitUntil(timeout: 5) { !self.audioConnected }
    log.result("Native SCO released=\(released). Confirm phone audio by listening on the phone.")
    return released
  }

  func dial(_ number: String) throws {
    guard !number.isEmpty, number.allSatisfy({ "+0123456789*#".contains($0) }) else {
      throw ProbeFailure.usage("dial number contains unsupported characters")
    }
    native?.dialNumber(number)
  }
  func answer() throws {
    guard let native, native.isConnected, state != .closed else {
      throw ProbeFailure.handsFree("Answer rejected: native service connection is not active")
    }
    log.step("Answer command received")
    log.detail("native state before Answer", "call=\(callActive) incoming=\(ringing)")
    guard !callActive else {
      log.result("A call is already active; no additional Answer command submitted")
      return
    }
    native.acceptCall()
    log.result("Answer submitted to native HFP command queue; acceptance awaits the call indicator")
  }
  func hangUp() { native?.endCall() }

  func waitForActiveCall(timeout: TimeInterval) async throws {
    log.step("Waiting for native call indicator")
    guard await waitUntil(timeout: timeout, { self.callActive }) else {
      throw ProbeFailure.call("no active call within \(timeout)s")
    }
    state = .callActive
  }

  func close() {
    native?.delegate = nil
    native?.transferAudioToPhone()
    native?.disconnectSCO()
    native?.disconnect()
    native = nil
    state = .closed
  }

  // Native callbacks may arrive on another thread. Copy only scalar values
  // before entering the main actor; no native objects cross executors.
  nonisolated func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
    let value = status?.int32Value ?? kIOReturnError
    Task { @MainActor in
      guard self.native != nil else { return }
      self.connectionStatus = value
      self.log.detail("native SLC callback", String(value))
    }
  }
  nonisolated func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
    Task { @MainActor in self.state = .closed }
  }
  nonisolated func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
    let value = status?.int32Value ?? kIOReturnError
    Task { @MainActor in
      guard self.native != nil else { return }
      self.scoStatus = value
      self.log.detail("native SCO callback", value.fourCCDescription)
    }
  }
  nonisolated func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
    let value = status?.int32Value ?? kIOReturnError
    Task { @MainActor in self.log.detail("native SCO closed", String(value)) }
  }
  nonisolated func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
  nonisolated func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
  nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
    Task { @MainActor in
      self.sdpQueryStatus = status
      self.sdpQueryFinished = true
      self.log.detail("sdpQueryComplete", status.fourCCDescription)
    }
  }
}
