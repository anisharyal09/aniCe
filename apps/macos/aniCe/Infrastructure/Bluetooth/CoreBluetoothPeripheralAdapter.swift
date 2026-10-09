// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import CoreBluetooth
import Foundation
import os

@MainActor protocol PairingPeripheralAdapter: PeripheralAdapter {
  var pairingWrite: ((Data) -> Bool)? { get set }
  var pairingDisconnect: (() -> Void)? { get set }
  func sendPairing(_ message: Data) throws
  func drainPairing() async
  func retirePairingConnection()
}

enum PeripheralMode { case idle, discovery, pairing, trustedSession }
@MainActor protocol SessionPeripheralAdapter: PairingPeripheralAdapter {
  var sessionWrite: ((Data) -> Bool)? { get set }
  var sessionDisconnect: (() -> Void)? { get set }
  var sessionAdmitted: (() -> Bool)? { get set }
  func sessionCapacity(_ bytes: Int) -> Bool
  func sendSession(_ message: Data) async throws
  func resumeSessionAdvertising()
  func tickSessionTransport() throws
}

/// Serialize advertising across windows because callbacks carry no application token.
struct AdvertisingGate {
  private(set) var generation = 0
  private(set) var active = false
  private var wanted: Int?
  private var inFlight: Int?
  private var confirmed: Int?
  var isConfirmed: Bool { active && confirmed == generation }
  var hasPendingRequest: Bool { inFlight != nil }
  mutating func begin() {
    generation += 1
    active = true
    confirmed = nil
    wanted = nil
  }
  mutating func stop() {
    generation += 1
    active = false
    wanted = nil
    confirmed = nil
  }
  mutating func request() { if active { wanted = generation } }
  mutating func takeRequest() -> Bool {
    guard active, wanted == generation, confirmed != generation, inFlight == nil else {
      return false
    }
    inFlight = generation
    return true
  }
  mutating func complete() -> Bool {
    let operation = inFlight
    inFlight = nil
    guard active, operation == generation, wanted == generation else { return false }
    confirmed = generation
    return true
  }
  mutating func resetRadio() {
    inFlight = nil
    confirmed = nil
    wanted = nil
  }
}

@MainActor
final class CoreBluetoothPeripheralAdapter: NSObject, SessionPeripheralAdapter,
  @preconcurrency CBPeripheralManagerDelegate
{
  private var manager: CBPeripheralManager?
  private var characteristic: CBMutableCharacteristic?
  private var profile: CBMutableService?
  private var published = false
  private var publishing = false
  private var advertising = AdvertisingGate()
  private static let logger = Logger(
    subsystem: "io.github.anisharyal09.anice", category: "pairing-radio")
  private var event: ((PeripheralEvent) -> Void)?
  private var read: ((Bool, Int) -> DiscoveryRead)?

  private(set) var mode: PeripheralMode = .idle
  var sessionWrite: ((Data) -> Bool)?
  var sessionDisconnect: (() -> Void)?
  var sessionAdmitted: (() -> Bool)?
  private var channelGeneration = 0
  private var sessionReceived = GattReassembler(version: 2)
  private var queueBudget = GattQueueBudget()
  var pairingWrite: ((Data) -> Bool)?
  var pairingDisconnect: (() -> Void)?
  private var incoming: CBMutableCharacteristic?
  private var outgoing: CBMutableCharacteristic?
  private var central: CBCentral?
  private var retiredCentrals = Set<UUID>()
  private var blockImplicitSubscriptions = false
  private struct PendingFragment {
    let bytes: Data
    let logicalSize: Int
  }
  private var queue: [PendingFragment] = []
  private var sendID: UInt64 = 0
  private var received = PairingReassembler()
  private var trafficBudget = 0
  func sendPairing(_ message: Data) throws {
    guard advertising.isConfirmed, pairingWrite != nil, let central, outgoing != nil,
      trafficBudget + message.count <= 32768, queueBudget.canReserve(message.count)
    else { throw PairingFailure.transport }
    let frames = try PairingReassembler.fragments(
      message, id: sendID, capacity: central.maximumUpdateValueLength)
    try append(frames, message.count)
    sendID += 1
    trafficBudget += message.count
    flush()
  }
  private func append(_ frames: [Data], _ size: Int) throws {
    try queueBudget.reserve(size)
    queue += frames.enumerated().map {
      PendingFragment(bytes: $0.element, logicalSize: $0.offset == frames.count - 1 ? size : 0)
    }
  }
  func sessionCapacity(_ bytes: Int) -> Bool {
    mode == .trustedSession && sessionWrite != nil && central != nil
      && queueBudget.canReserve(bytes)
  }
  // An empty queue proves Core Bluetooth accepted submission, not remote delivery.
  func sendSession(_ message: Data) async throws {
    guard sessionCapacity(message.count), let central else { throw SessionBackpressure() }
    let op = channelGeneration
    try append(
      try GattReassembler.fragments(
        message, id: sendID, capacity: central.maximumUpdateValueLength, version: 2), message.count)
    sendID += 1
    flush()
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while !queue.isEmpty {
      guard op == channelGeneration, self.central != nil else { throw SessionFailure.cancelled }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        retirePairingConnection()
        throw SessionFailure.expired
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard op == channelGeneration else { throw SessionFailure.cancelled }
  }
  func tickSessionTransport() throws { try sessionReceived.tick() }
  func resumeSessionAdvertising() {
    guard mode == .trustedSession, central == nil else { return }
    advertising.begin()
    advertise()
  }
  private func disconnected() {
    if mode == .trustedSession { sessionDisconnect?() } else { pairingDisconnect?() }
  }
  // Stop advertising after admission; established writes use the candidate, not advertising state.
  private func admit(_ candidate: CBCentral) -> Bool {
    guard mode == .trustedSession else { return true }
    guard advertising.isConfirmed, sessionAdmitted?() == true else {
      Self.logger.info("candidate_admission accepted=false advertising=\(self.advertising.isConfirmed)")
      return false
    }
    Self.logger.info("candidate_admission accepted=true")
    advertising.stop()
    manager?.stopAdvertising()
    return true
  }
  private func flush() {
    guard let manager, let central, let outgoing else { return }
    while let value = queue.first {
      guard manager.updateValue(value.bytes, for: outgoing, onSubscribedCentrals: [central]) else {
        return
      }
      let completed = queue.removeFirst()
      if completed.logicalSize > 0 { queueBudget.release(completed.logicalSize) }
    }
  }
  /// Give backpressured cancellation frames a bounded chance to reach Core Bluetooth.
  /// An empty queue means submission, not proof of delivery to the remote application.
  func drainPairing() async {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !queue.isEmpty, central != nil, ProcessInfo.processInfo.systemUptime < deadline {
      do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
    }
  }
  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    guard peripheral === manager else { return }
    flush()
  }
  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    Self.logger.info("subscription mode_session=\(self.mode == .trustedSession) advertising=\(self.advertising.isConfirmed)")
    guard peripheral === manager, advertising.isConfirmed,
      pairingWrite != nil || sessionWrite != nil,
      characteristic.uuid == outgoing?.uuid
    else { return }
    retiredCentrals.remove(central.identifier)
    guard self.central == nil else { return }
    guard admit(central) else { return }
    self.central = central
    queue.removeAll()
    queueBudget.clear()
    sessionReceived = GattReassembler(version: 2)
    sendID = 0
    trafficBudget = 0
    received = PairingReassembler()
  }
  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    guard peripheral === manager else { return }
    retiredCentrals.remove(central.identifier)
    guard self.central?.identifier == central.identifier else { return }
    resetPairingChannel()
    disconnected()
  }
  func peripheralManager(
    _ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]
  ) {
    guard let first = requests.first else { return }
    guard peripheral === manager,
      mode == .trustedSession
        ? sessionWrite != nil : advertising.isConfirmed && pairingWrite != nil
    else {
      Self.logger.info("session_write permission_rejected=true mode_session=\(self.mode == .trustedSession)")
      peripheral.respond(to: first, withResult: .writeNotPermitted)
      return
    }
    if GattCandidateAdmission.mayReuseSubscription(
      hasCandidate: central != nil, advertising: advertising.isConfirmed,
      subscribed: outgoing?.subscribedCentrals?.contains(where: {
        $0.identifier == first.central.identifier
      }) == true,
      retired: retiredCentrals.contains(first.central.identifier),
      blocked: blockImplicitSubscriptions
    ) {
      // Core Bluetooth may retain a subscription without another didSubscribe callback.
      // An explicit new window may admit it, but EDHOC and readiness must run afresh.
      // Invalid candidates remain blocked within the window until they subscribe again.
      if mode == .trustedSession, !admit(first.central) {
        peripheral.respond(to: first, withResult: .writeNotPermitted)
        return
      }
      Self.logger.info("candidate_admission reused_subscription=true")
      central = first.central
      sessionReceived = GattReassembler(version: 2)
      sendID = 0
      trafficBudget = 0
      received = PairingReassembler()
    }
    do {
      for request in requests {
        guard peripheral === manager, request.characteristic.uuid == incoming?.uuid,
          request.offset == 0,
          request.central.identifier == central?.identifier, let value = request.value
        else { throw PairingFailure.transport }
        if mode == .trustedSession {
          if let message = try sessionReceived.receive(value) {
            guard sessionWrite?(message) == true else { throw SessionFailure.state }
          }
        } else if let message = try received.receive(value) {
          guard trafficBudget + message.count <= 32768 else { throw PairingFailure.transport }
          trafficBudget += message.count
          guard pairingWrite?(message) == true else { throw PairingFailure.expired }
        }
      }
      peripheral.respond(to: first, withResult: .success)
    } catch {
      Self.logger.info("session_write rejected=true candidate_match=\(first.central.identifier == self.central?.identifier) version2=\(first.value?.first == 2)")
      peripheral.respond(to: first, withResult: .unlikelyError)
      // A malformed unauthenticated frame must not stop the invitation.
      if first.central.identifier == central?.identifier {
        retirePairingConnection()
        disconnected()
      }
    }
  }

  /// Core Bluetooth cannot force a central to disconnect. Retire its application
  /// channel so further writes are rejected until it subscribes on a new attempt.
  func retirePairingConnection() {
    if let central {
      if retiredCentrals.count < 32 {
        retiredCentrals.insert(central.identifier)
      } else {
        blockImplicitSubscriptions = true
      }
    }
    resetPairingChannel()
  }
  private func resetPairingChannel() {
    channelGeneration += 1
    central = nil
    queue.removeAll()
    queueBudget.clear()
    sessionReceived = GattReassembler(version: 2)
    received = PairingReassembler()
    sendID = 0
    trafficBudget = 0
  }

  func begin(
    event: @escaping (PeripheralEvent) -> Void, read: @escaping (Bool, Int) -> DiscoveryRead
  ) {
    mode = sessionWrite != nil ? .trustedSession : pairingWrite != nil ? .pairing : .discovery
    advertising.begin()
    self.event = event
    self.read = read
    switch CBManager.authorization {
    case .notDetermined: event(.permissionPending)
    case .denied, .restricted:
      event(.denied)
      return
    case .allowedAlways: event(.initializing)
    @unknown default:
      event(.failure)
      return
    }
    if let manager {
      peripheralManagerDidUpdateState(manager)
    } else {
      manager = CBPeripheralManager(
        delegate: self, queue: nil,
        options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
    }
  }
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard peripheral === manager else { return }
    if peripheral.state != .poweredOn {
      // Core Bluetooth owns database invalidation on radio reset/power loss.
      published = false
      publishing = false
      profile = nil
      characteristic = nil
      incoming = nil
      outgoing = nil
      advertising.resetRadio()
      retirePairingConnection()
      disconnected()
      // Keep the state observer through radio-off/reset so automatic availability can recover.
      if peripheral.state == .unauthorized || peripheral.state == .unsupported
      {
        peripheral.delegate = nil
        manager = nil
      }
    }
    switch peripheral.state {
    case .poweredOn: event?(.available)
    case .poweredOff: event?(.off)
    case .unauthorized: event?(.denied)
    case .unsupported: event?(.unsupported)
    case .resetting: event?(.resetting)
    case .unknown:
      event?(CBManager.authorization == .notDetermined ? .permissionPending : .initializing)
    @unknown default: event?(.failure)
    }
  }
  /// The public UUID layout is constant in every mode. Access is gated separately.
  static func makeProfile() -> CBMutableService {
    let service = CBMutableService(type: CBUUID(string: BlePayloadCodec.serviceUUID), primary: true)
    service.characteristics = [
      CBMutableCharacteristic(
        type: CBUUID(string: BlePayloadCodec.characteristicUUID), properties: .read, value: nil,
        permissions: .readable),
      CBMutableCharacteristic(
        type: CBUUID(string: PairingCodec.writeUUID), properties: .write, value: nil,
        permissions: .writeable),
      CBMutableCharacteristic(
        type: CBUUID(string: PairingCodec.indicateUUID), properties: .indicate, value: nil,
        permissions: .readable),
    ]
    return service
  }
  func publish() {
    guard let manager, manager.state == .poweredOn else {
      event?(.failure)
      return
    }
    if published {
      Self.logger.info("profile_reuse characteristic_count=3")
      event?(.published)
      return
    }
    guard !publishing else { return }
    let service = Self.makeProfile()
    profile = service
    characteristic = service.characteristics?[0] as? CBMutableCharacteristic
    incoming = service.characteristics?[1] as? CBMutableCharacteristic
    outgoing = service.characteristics?[2] as? CBMutableCharacteristic
    publishing = true
    Self.logger.info("profile_publish characteristic_count=3")
    manager.add(service)
  }
  func peripheralManager(
    _ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?
  ) {
    guard peripheral === manager, service === profile else { return }
    publishing = false
    published = error == nil
    Self.logger.info("profile_publication succeeded=\(error == nil, privacy: .public)")
    event?(published ? .published : .failure)
  }
  func advertise() {
    advertising.request()
    startQueuedAdvertising()
  }
  private func startQueuedAdvertising() {
    guard let manager, manager.state == .poweredOn, published, advertising.takeRequest() else {
      return
    }
    manager.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BlePayloadCodec.serviceUUID)],
      CBAdvertisementDataLocalNameKey: "aniCe",
    ])
  }
  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    guard peripheral === manager else { return }
    if advertising.complete() {
      Self.logger.info("advertising_confirmation succeeded=\(error == nil, privacy: .public)")
      event?(error == nil ? .advertising : .failure)
    } else {
      // An old window's late callback cannot confirm a new invitation.
      peripheral.stopAdvertising()
      startQueuedAdvertising()
    }
  }
  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard peripheral === manager else {
      peripheral.respond(to: request, withResult: .unlikelyError)
      return
    }
    let result =
      read?(
        characteristic != nil && request.characteristic.uuid == characteristic?.uuid, request.offset
      ) ?? .unavailable
    switch result {
    case .value(let data):
      request.value = data
      peripheral.respond(to: request, withResult: .success)
    case .invalidOffset: peripheral.respond(to: request, withResult: .invalidOffset)
    case .unknownCharacteristic: peripheral.respond(to: request, withResult: .attributeNotFound)
    case .unavailable: peripheral.respond(to: request, withResult: .unlikelyError)
    }
  }
  func stop() {
    mode = .idle
    let incompleteStartup = publishing || advertising.hasPendingRequest
    advertising.stop()
    event = nil
    read = nil
    resetPairingChannel()
    retiredCentrals.removeAll()
    blockImplicitSubscriptions = false
    manager?.stopAdvertising()
    if incompleteStartup {
      // A missing publication/advertising callback must not poison every explicit retry.
      manager?.delegate = nil
      manager = nil
      profile = nil
      published = false
      publishing = false
      characteristic = nil
      incoming = nil
      outgoing = nil
      advertising.resetRadio()
    }
    // Preserve the fixed public attribute table across discovery/pairing windows.
    // Reads/writes remain unavailable without the live session callbacks above.
    // The OS releases the manager/database when the app quits.
  }
}
