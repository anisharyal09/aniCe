@preconcurrency import CoreBluetooth
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

@MainActor protocol PairingPeripheralAdapter: PeripheralAdapter {
  var pairingWrite: ((Data) -> Bool)? { get set }
  var pairingDisconnect: (() -> Void)? { get set }
  func sendPairing(_ message: Data) throws
  func drainPairing() async
  func retirePairingConnection()
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
final class CoreBluetoothPeripheralAdapter: NSObject, PairingPeripheralAdapter,
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

  var pairingWrite: ((Data) -> Bool)?
  var pairingDisconnect: (() -> Void)?
  private var incoming: CBMutableCharacteristic?
  private var outgoing: CBMutableCharacteristic?
  private var central: CBCentral?
  private var retiredCentrals = Set<UUID>()
  private var blockImplicitSubscriptions = false
  private var queue: [Data] = []
  private var sendID: UInt64 = 0
  private var received = PairingReassembler()
  private var trafficBudget = 0
  func sendPairing(_ message: Data) throws {
    guard advertising.isConfirmed, pairingWrite != nil, let central, outgoing != nil,
      trafficBudget + message.count <= 32768
    else { throw PairingFailure.transport }
    queue += try PairingReassembler.fragments(
      message, id: sendID, capacity: central.maximumUpdateValueLength)
    sendID += 1
    trafficBudget += message.count
    flush()
  }
  private func flush() {
    guard let manager, let central, let outgoing else { return }
    while let value = queue.first {
      guard manager.updateValue(value, for: outgoing, onSubscribedCentrals: [central]) else {
        return
      }
      queue.removeFirst()
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
    guard peripheral === manager, advertising.isConfirmed, pairingWrite != nil,
      characteristic.uuid == outgoing?.uuid
    else { return }
    retiredCentrals.remove(central.identifier)
    guard self.central == nil else { return }
    self.central = central
    queue.removeAll()
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
    self.central = nil
    queue.removeAll()
    received = PairingReassembler()
    pairingDisconnect?()
  }
  func peripheralManager(
    _ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]
  ) {
    guard let first = requests.first else { return }
    guard peripheral === manager, advertising.isConfirmed, pairingWrite != nil else {
      peripheral.respond(to: first, withResult: .writeNotPermitted)
      return
    }
    if central == nil, !blockImplicitSubscriptions,
      !retiredCentrals.contains(first.central.identifier),
      outgoing?.subscribedCentrals?.contains(where: { $0.identifier == first.central.identifier })
        == true
    {
      // A Core Bluetooth subscription can outlive advertising. A new live invitation
      // may reuse it, but a channel retired for invalid traffic must subscribe afresh.
      central = first.central
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
        if let message = try received.receive(value) {
          guard trafficBudget + message.count <= 32768 else { throw PairingFailure.transport }
          trafficBudget += message.count
          guard pairingWrite?(message) == true else { throw PairingFailure.expired }
        }
      }
      peripheral.respond(to: first, withResult: .success)
    } catch {
      peripheral.respond(to: first, withResult: .unlikelyError)
      // A malformed unauthenticated frame must not stop the invitation.
      if first.central.identifier == central?.identifier {
        retirePairingConnection()
        pairingDisconnect?()
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
    central = nil
    queue.removeAll()
    received = PairingReassembler()
    sendID = 0
    trafficBudget = 0
  }

  func begin(
    event: @escaping (PeripheralEvent) -> Void, read: @escaping (Bool, Int) -> DiscoveryRead
  ) {
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
      if peripheral.state == .poweredOff || peripheral.state == .resetting
        || peripheral.state == .unauthorized || peripheral.state == .unsupported
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
