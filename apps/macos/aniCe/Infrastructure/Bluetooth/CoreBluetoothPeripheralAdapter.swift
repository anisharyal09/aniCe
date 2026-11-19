// SPDX-License-Identifier: GPL-3.0-or-later
// Owns native peripheral admission, ordered GATT messages and bounded session submissions.
@preconcurrency import CoreBluetooth
import Foundation
import os

@MainActor protocol PairingPeripheralAdapter: PeripheralAdapter {
  var pairingWrite: ((Data) -> Bool)? { get set }
  var pairingDisconnect: (() -> Void)? { get set }
  var pairingAdmitted: (() -> Bool)? { get set }
  func sendPairing(_ message: Data) throws
  func drainPairing() async
  func retirePairingConnection()
}

extension PairingPeripheralAdapter {
  var pairingAdmitted: (() -> Bool)? { get { nil } set {} }
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
  var sessionDeadline: TimeInterval? { get }
  var sessionChanged: (() -> Void)? { get set }
}

extension SessionPeripheralAdapter {
  var sessionDeadline: TimeInterval? { nil }
  var sessionChanged: (() -> Void)? { get { nil } set {} }
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

@MainActor final class GattSubmissionWaiters {
  private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
  func contains(_ token: UUID) -> Bool { pending[token] != nil }
  func insert(_ token: UUID, _ continuation: CheckedContinuation<Void, Error>) {
    precondition(pending[token] == nil)
    pending[token] = continuation
  }
  func complete(_ token: UUID) { pending.removeValue(forKey: token)?.resume() }
  func retire() {
    let old = pending
    pending.removeAll()
    for continuation in old.values { continuation.resume(throwing: SessionFailure.cancelled) }
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
  var pairingAdmitted: (() -> Bool)?
  private var incoming: CBMutableCharacteristic?
  private var outgoing: CBMutableCharacteristic?
  private var central: CBCentral?
  private var retiredCentrals = Set<UUID>()
  private var blockImplicitSubscriptions = false
  private struct PendingFragment {
    let bytes: Data
    let logicalSize: Int
    var submission: UUID? = nil
  }
  private var queue: [PendingFragment] = []
  private let submissions = GattSubmissionWaiters()
  private var submissionDeadlines: [UUID: Task<Void, Never>] = [:]
  private var sendID: UInt64 = 0
  private var received = PairingReassembler()
  private var trafficBudget = 0
  private var companionSetupAdvertising = false
  /// Advertise the existing service for an approved setup chooser without changing its occupied slot.
  func setCompanionSetupAdvertising(_ enabled: Bool) -> Bool {
    guard mode == .trustedSession, central != nil, let manager, manager.state == .poweredOn, published
    else { return false }
    if enabled {
      if companionSetupAdvertising { return true }
      companionSetupAdvertising = true
      advertising.begin()
      advertise()
    } else {
      companionSetupAdvertising = false
      advertising.stop()
      manager.stopAdvertising()
    }
    return true
  }
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
    let token = UUID()
    let frames = try GattReassembler.fragments(
      message, id: sendID, capacity: central.maximumUpdateValueLength, version: 2)
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        do { try append(frames, message.count) }
        catch { continuation.resume(throwing: error); return }
        sendID += 1
        queue[queue.count - 1].submission = token
        submissions.insert(token, continuation)
        submissionDeadlines[token] = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(10)) } catch { return }
          guard let self, op == self.channelGeneration, self.submissions.contains(token) else { return }
          self.retirePairingConnection()
          self.disconnected()
        }
        flush()
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, op == self.channelGeneration, self.submissions.contains(token) else { return }
        // Cancellation after sealing retires the channel; a partial record cannot be replayed.
        self.retirePairingConnection()
        self.disconnected()
      }
    }
    guard op == channelGeneration else { throw SessionFailure.cancelled }
  }
  var sessionChanged: (() -> Void)?
  var sessionDeadline: TimeInterval? { sessionReceived.nextDeadline }
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
    if mode == .pairing { return pairingAdmitted?() ?? true }
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
      if let token = completed.submission {
        submissionDeadlines.removeValue(forKey: token)?.cancel()
        submissions.complete(token)
      }
      if completed.logicalSize > 0 { queueBudget.release(completed.logicalSize); sessionChanged?() }
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
    let subscribed = outgoing?.subscribedCentrals?.contains {
      $0.identifier == central.identifier
    } == true
    guard GattCandidateAdmission.mayRetireSubscription(
      candidateMatches: self.central?.identifier == central.identifier,
      characteristicMatches: characteristic === outgoing,
      subscriptionRemains: subscribed
    ) else {
      Self.logger.notice("unsubscribe_ignored current_subscription=\(subscribed) characteristic_match=\(characteristic === self.outgoing) generation=\(self.channelGeneration)")
      return
    }
    retiredCentrals.remove(central.identifier)
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
      Self.logger.notice("session_write permission_rejected=true mode_session=\(self.mode == .trustedSession) generation=\(self.channelGeneration)")
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
      if (mode == .trustedSession || mode == .pairing), !admit(first.central) {
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
          sessionChanged?()
        } else if let message = try received.receive(value) {
          guard trafficBudget + message.count <= 32768 else { throw PairingFailure.transport }
          trafficBudget += message.count
          guard pairingWrite?(message) == true else { throw PairingFailure.expired }
        }
      }
      peripheral.respond(to: first, withResult: .success)
    } catch {
      Self.logger.notice("session_write rejected=true mode=\(String(describing: self.mode), privacy: .public) generation=\(self.channelGeneration) candidate_match=\(first.central.identifier == self.central?.identifier) characteristic_match=\(first.characteristic.uuid == self.incoming?.uuid) offset=\(first.offset) version2=\(first.value?.first == 2) reason=\(String(describing: error), privacy: .public)")
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
    if companionSetupAdvertising {
      advertising.stop()
      manager?.stopAdvertising()
    }
    companionSetupAdvertising = false
    channelGeneration += 1
    for task in submissionDeadlines.values { task.cancel() }
    submissionDeadlines.removeAll()
    submissions.retire()
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
    Self.logger.info("peripheral_state state=\(peripheral.state.rawValue) authorization=\(CBManager.authorization.rawValue) generation=\(self.channelGeneration)")
    if peripheral.state != .poweredOn {
      // Powered-off pauses advertising but retains the database; re-adding duplicates the service.
      if Self.invalidatesServices(peripheral.state) {
        published = false
        publishing = false
        profile = nil
        characteristic = nil
        incoming = nil
        outgoing = nil
      }
      advertising.resetRadio()
      retirePairingConnection()
      // The state event retires the owner before any reconnect decision; retain its native observer.
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
  nonisolated static func invalidatesServices(_ state: CBManagerState) -> Bool {
    state.rawValue < CBManagerState.poweredOff.rawValue
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
        permissions: [.readable, .writeable]),
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
    if let error = error as NSError? {
      Self.logger.notice("profile_publication domain=\(error.domain, privacy: .public) code=\(error.code) generation=\(self.channelGeneration)")
    }
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
    if let error = error as NSError? {
      Self.logger.notice("advertising domain=\(error.domain, privacy: .public) code=\(error.code) generation=\(self.advertising.generation)")
    }
    if advertising.complete() {
      Self.logger.info("advertising_confirmation succeeded=\(error == nil, privacy: .public)")
      if companionSetupAdvertising {
        if error != nil {
          companionSetupAdvertising = false
          advertising.stop()
          peripheral.stopAdvertising()
        }
        return
      }
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
    let matches = characteristic != nil && request.characteristic.uuid == characteristic?.uuid
    let result = read?(matches, request.offset) ?? .unavailable
    // State-only diagnostics: never log native central identifiers, tokens or payload bytes.
    Self.logger.notice("discovery_read mode=\(String(describing: self.mode), privacy: .public) matches=\(matches) offset=\(request.offset) owner=\(self.read != nil) published=\(self.published) advertising=\(self.advertising.isConfirmed)")
    switch result {
    case .value(let data):
      Self.logger.notice("discovery_read result=value bytes=\(data.count) generation=\(self.channelGeneration)")
      request.value = data
      peripheral.respond(to: request, withResult: .success)
    case .invalidOffset:
      Self.logger.notice("discovery_read result=invalid_offset generation=\(self.channelGeneration)")
      peripheral.respond(to: request, withResult: .invalidOffset)
    case .unknownCharacteristic:
      Self.logger.notice("discovery_read result=unknown_characteristic generation=\(self.channelGeneration)")
      peripheral.respond(to: request, withResult: .attributeNotFound)
    case .unavailable:
      Self.logger.notice("discovery_read unavailable=true")
      peripheral.respond(to: request, withResult: .unlikelyError)
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
