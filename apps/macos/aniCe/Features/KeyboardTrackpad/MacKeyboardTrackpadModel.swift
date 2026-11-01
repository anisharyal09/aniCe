// SPDX-License-Identifier: GPL-3.0-or-later
// Owns trusted-phone selection, local Bluetooth associations, focused HID capture and bounded typing jobs.
import AppKit
import Foundation
import Observation

struct PairedBluetoothDevice: Equatable, Identifiable, Sendable {
  let address: String
  let name: String
  var id: String { address }
}

enum KeyboardTrackpadTransportResult: Equatable, Sendable {
  case success
  case failure(String)
}

enum KeyboardTrackpadTransportEvent: Equatable, Sendable {
  case changed(generation: UInt64, ready: Bool, suspended: Bool, reportProtocol: Bool, message: String?)
}

typealias KeyboardTrackpadDevicesCompletion = @MainActor @Sendable ([PairedBluetoothDevice]) -> Void
typealias KeyboardTrackpadResultCompletion = @MainActor @Sendable (KeyboardTrackpadTransportResult) -> Void
typealias KeyboardTrackpadVoidCompletion = @MainActor @Sendable () -> Void

@MainActor protocol KeyboardTrackpadTransport: AnyObject {
  var stateChanged: (@MainActor @Sendable (KeyboardTrackpadTransportEvent) -> Void)? { get set }
  func pairedDevices(_ completion: @escaping KeyboardTrackpadDevicesCompletion)
  func connect(address: String, generation: UInt64, completion: @escaping KeyboardTrackpadResultCompletion)
  func keyboard(modifiers: UInt8, usages: [UInt8], completion: @escaping KeyboardTrackpadResultCompletion)
  func mouse(buttons: UInt8, deltaX: Int, deltaY: Int, wheel: Int, completion: @escaping KeyboardTrackpadResultCompletion)
  func navigation(usage: UInt16, pressed: Bool, completion: @escaping KeyboardTrackpadResultCompletion)
  func disconnect(completion: @escaping KeyboardTrackpadVoidCompletion)
  func shutdown()
}

@MainActor final class ClassicHIDTransport: KeyboardTrackpadTransport {
  // The Objective-C boundary delivers every callback on DispatchQueue.main.
  private let adapter = AniCeHIDAdapter()
  var stateChanged: (@MainActor @Sendable (KeyboardTrackpadTransportEvent) -> Void)?

  init() {
    adapter.stateChanged = { [weak self] generation, ready, suspended, reportProtocol, message in
      let event = KeyboardTrackpadTransportEvent.changed(generation: generation, ready: ready, suspended: suspended, reportProtocol: reportProtocol, message: message)
      MainActor.assumeIsolated { self?.stateChanged?(event) }
    }
  }

  func pairedDevices(_ completion: @escaping KeyboardTrackpadDevicesCompletion) {
    adapter.enumeratePairedDevices { values in
      let devices: [PairedBluetoothDevice] = values.compactMap { value in
        guard let address = value["address"], let name = value["name"] else { return nil }
        return PairedBluetoothDevice(address: address, name: name)
      }
      MainActor.assumeIsolated { completion(devices) }
    }
  }

  func connect(address: String, generation: UInt64, completion: @escaping KeyboardTrackpadResultCompletion) {
    _ = adapter.connectAddress(address, generation: generation) { success, message in
      let result: KeyboardTrackpadTransportResult = success ? .success : .failure(message ?? "Bluetooth HID could not connect.")
      MainActor.assumeIsolated { completion(result) }
    }
  }

  func keyboard(modifiers: UInt8, usages: [UInt8], completion: @escaping KeyboardTrackpadResultCompletion) {
    _ = adapter.sendKeyboardModifiers(modifiers, usages: usages.map { NSNumber(value: $0) }) { success, message in
      let result: KeyboardTrackpadTransportResult = success ? .success : .failure(message ?? "The keyboard report could not be sent.")
      MainActor.assumeIsolated { completion(result) }
    }
  }

  func mouse(buttons: UInt8, deltaX: Int, deltaY: Int, wheel: Int, completion: @escaping KeyboardTrackpadResultCompletion) {
    _ = adapter.sendMouseButtons(buttons, deltaX: deltaX, deltaY: deltaY, wheel: wheel) { success, message in
      let result: KeyboardTrackpadTransportResult = success ? .success : .failure(message ?? "The mouse report could not be sent.")
      MainActor.assumeIsolated { completion(result) }
    }
  }

  func navigation(usage: UInt16, pressed: Bool, completion: @escaping KeyboardTrackpadResultCompletion) {
    _ = adapter.sendNavigationUsage(usage, pressed: pressed) { success, message in
      let result: KeyboardTrackpadTransportResult = success ? .success : .failure(message ?? "The navigation action could not be sent.")
      MainActor.assumeIsolated { completion(result) }
    }
  }

  func disconnect(completion: @escaping KeyboardTrackpadVoidCompletion) {
    _ = adapter.disconnect { MainActor.assumeIsolated { completion() } }
  }
  func shutdown() { adapter.shutdown() }
}

enum KeyboardTrackpadPhase: Equatable {
  case setupNeeded
  case disconnected
  case connecting
  case connectedIdle
  case controlling
  case suspended
  case disconnecting
  case failed
}

enum KeyboardTrackpadSurface: Hashable, Sendable { case keyboard, pad }

struct KeyboardTrackpadCaptureOwner: Equatable, Sendable {
  let presentationID: UUID
  let inputID: UUID
  let surface: KeyboardTrackpadSurface
}

enum KeyboardTrackpadSpeed: String, CaseIterable, Identifiable {
  case extraSlow, gentle, standard, fast
  var id: Self { self }
  var title: String {
    switch self {
    case .extraSlow: "Extra slow"
    case .gentle: "Gentle"
    case .standard: "Standard"
    case .fast: "Fast"
    }
  }
  var scale: Double {
    switch self {
    case .extraSlow: 0.125
    case .gentle: 0.5
    case .standard: 1.0
    case .fast: 2.0
    }
  }
}

struct KeyboardTrackpadKeyStroke: Equatable, Sendable {
  let usage: UInt8
  let modifiers: UInt8
}

enum ClipboardTypingValidationError: Error, Equatable {
  case empty
  case tooLong
  case unsupported(UInt32)
}

@MainActor final class KeyboardTrackpadAssociations {
  private static let key = "keyboardTrackpad.bluetoothAssociations"
  private let storage: UserDefaults?
  private var values: [String: String]

  init(storage: UserDefaults? = .standard) {
    self.storage = storage
    values = storage?.dictionary(forKey: Self.key) as? [String: String] ?? [:]
  }

  static func peerKey(_ peer: DeviceIdentity) -> String { peer.deviceId + ":" + peer.fingerprint }

  func address(for peer: DeviceIdentity) -> String? {
    let key = Self.peerKey(peer)
    guard let value = values[key] else { return nil }
    guard let normalized = AniCeHIDProtocol.normalizedAddress(value) else {
      values.removeValue(forKey: key)
      persist()
      return nil
    }
    if normalized != value { values[key] = normalized; persist() }
    return normalized
  }

  func associate(_ address: String, with peer: DeviceIdentity) -> Bool {
    guard let normalized = AniCeHIDProtocol.normalizedAddress(address) else { return false }
    let key = Self.peerKey(peer)
    // Called only after the user confirms Link device; reassignment is deliberate.
    values = values.filter { $0.key == key || AniCeHIDProtocol.normalizedAddress($0.value) != normalized }
    values[key] = normalized
    persist()
    return true
  }

  func prune(to peers: [DeviceIdentity]) {
    let retained = Set(peers.map(Self.peerKey))
    values = values.filter { retained.contains($0.key) && AniCeHIDProtocol.normalizedAddress($0.value) != nil }
    persist()
  }

  func clear() { values.removeAll(); persist() }
  private func persist() { storage?.set(values, forKey: Self.key) }
}

@Observable @MainActor final class MacKeyboardTrackpadModel {
  private struct Output {
    enum Payload: Equatable {
      case keyboard(UInt8, [UInt8])
      case mouse(UInt8, Int, Int, Int)
      case navigation(UInt16, Bool)
      case motion(UInt8, Double, Double, Double)
    }
    var generation: UInt64
    var captureEpoch: UInt64
    var payload: Payload
    var idleAllowed = false
    var release = false
    var completion: KeyboardTrackpadResultCompletion?
  }

  private struct NavigationJob {
    enum Stage: Equatable { case pressPending, holding, releasePending, releaseWhenPressed }
    let id: UInt64
    let usage: UInt16
    var stage: Stage = .pressPending
  }

  private struct KeyboardStep: Sendable {
    let modifiers: UInt8
    let usages: [UInt8]
    let delay: Duration
    var completedCharacters: Int?
  }

  private struct TypingJob: Sendable {
    let id: UInt64
    let steps: [KeyboardStep]
    let clipboard: Bool
    var index = 0
    var waiting = false
  }

  @ObservationIgnored private let transport: any KeyboardTrackpadTransport
  @ObservationIgnored private let preferences: UserDefaults
  @ObservationIgnored private let associations: KeyboardTrackpadAssociations
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var sleepObserver: NSObjectProtocol?
  @ObservationIgnored private var typingTimer: Task<Void, Never>?
  @ObservationIgnored private var motionTimer: Task<Void, Never>?
  @ObservationIgnored private var navigationTimer: Task<Void, Never>?
  @ObservationIgnored private var pendingDisconnect = false
  @ObservationIgnored private var disconnectStarted = false
  private var typingJob: TypingJob?
  private var navigationJob: NavigationJob?
  @ObservationIgnored private var nextTypingID: UInt64 = 0
  @ObservationIgnored private var nextNavigationID: UInt64 = 0
  @ObservationIgnored private var nextWriteID: UInt64 = 0
  private var writeInFlight = false
  private var isShuttingDown = false
  @ObservationIgnored private var explicitSelectionWasRevoked = false
  @ObservationIgnored private var heldUsages: [UInt8] = []
  @ObservationIgnored private var heldModifiers: UInt8 = 0
  private var heldButtons: UInt8 = 0
  @ObservationIgnored private var typeKeyDown = false
  @ObservationIgnored private var lastMotionWrite: ContinuousClock.Instant?
  private var associationRevision = 0

  private(set) var trustedPeers: [DeviceIdentity] = []
  private(set) var connectedPeerIDs: Set<String> = []
  private(set) var targetPeer: DeviceIdentity?
  private(set) var pairedDevices: [PairedBluetoothDevice] = []
  private(set) var pairedDevicesChecked = false
  private(set) var phase: KeyboardTrackpadPhase = .setupNeeded
  private(set) var relinkingAssociation = false
  private(set) var failureMessage: String?
  private(set) var notice: String?
  private(set) var reportProtocol = true
  private(set) var isTypingClipboard = false
  private(set) var typingProgress = 0
  private(set) var typingLength = 0
  var reverseVerticalPointer = true {
    didSet { preferences.set(reverseVerticalPointer, forKey: "keyboardTrackpad.reverseVerticalPointer") }
  }
  var pointerSpeed: KeyboardTrackpadSpeed = .standard {
    didSet { preferences.set(pointerSpeed.rawValue, forKey: "keyboardTrackpad.pointerSpeed") }
  }
  var scrollSpeed: KeyboardTrackpadSpeed = .extraSlow {
    didSet { preferences.set(scrollSpeed.rawValue, forKey: "keyboardTrackpad.scrollSpeed") }
  }

  private var connectionGeneration: UInt64 = 0
  private var captureEpoch: UInt64 = 0
  private var pairingRefreshGeneration: UInt64 = 0
  @ObservationIgnored private var panelRegistrations: [UUID: Bool] = [:]
  @ObservationIgnored private var automaticConnectionAttempts = Set<String>()
  private var activeSurface: KeyboardTrackpadSurface?
  private var pendingCaptureSurface: KeyboardTrackpadSurface?
  private var activeOwner: KeyboardTrackpadCaptureOwner?
  private var pendingOwner: KeyboardTrackpadCaptureOwner?
  private static let legacyPresentationID = UUID()
  private static let legacyKeyboardOwner = KeyboardTrackpadCaptureOwner(
    presentationID: legacyPresentationID, inputID: UUID(), surface: .keyboard)
  private static let legacyPadOwner = KeyboardTrackpadCaptureOwner(
    presentationID: legacyPresentationID, inputID: UUID(), surface: .pad)
  private var lastDeliberatePeerKey: String?
  private var connectedBLEPeerID: String?
  private var outputQueue: [Output] = []
  private enum ScrollAxis { case undecided, horizontal, vertical }
  private var scrollAxis: ScrollAxis?
  private var scrollX = 0.0
  private var scrollY = 0.0
  private var scrollDragging = false

  init(
    transport: any KeyboardTrackpadTransport = ClassicHIDTransport(),
    preferences: UserDefaults = .standard
  ) {
    self.transport = transport
    self.preferences = preferences
    associations = KeyboardTrackpadAssociations(storage: preferences)
    if let raw = preferences.string(forKey: "keyboardTrackpad.scrollSpeed"),
       let stored = KeyboardTrackpadSpeed(rawValue: raw) {
      scrollSpeed = stored
    }
    if preferences.object(forKey: "keyboardTrackpad.reverseVerticalPointer") != nil {
      reverseVerticalPointer = preferences.bool(forKey: "keyboardTrackpad.reverseVerticalPointer")
    }
    if let raw = preferences.string(forKey: "keyboardTrackpad.pointerSpeed"),
       let speed = KeyboardTrackpadSpeed(rawValue: raw) {
      pointerSpeed = speed
    }
    transport.stateChanged = { [weak self] event in self?.transportChanged(event) }
    installLifecycleObservers()
  }

  var targetKey: String? { targetPeer.map(KeyboardTrackpadAssociations.peerKey) }
  var targetAddress: String? {
    _ = associationRevision
    guard let targetPeer else { return nil }
    return associations.address(for: targetPeer)
  }
  var matchingPairedDevices: [PairedBluetoothDevice] {
    guard let targetPeer else { return [] }
    return pairedDevices.filter { $0.name.localizedCaseInsensitiveCompare(targetPeer.deviceName) == .orderedSame }
  }
  var isLinkedDevicePaired: Bool {
    guard let address = targetAddress else { return false }
    return pairedDevices.contains { $0.address == address }
  }
  var needsDeviceLink: Bool {
    if relinkingAssociation { return true }
    guard targetAddress != nil else { return true }
    if phase == .connecting || phase == .connectedIdle || phase == .controlling || phase == .suspended { return false }
    return !pairedDevicesChecked || !isLinkedDevicePaired
  }
  var canConnect: Bool { targetPeer != nil && targetAddress != nil && isLinkedDevicePaired && !needsDeviceLink && phase != .connecting && phase != .disconnecting }
  var isReady: Bool { phase == .connectedIdle || phase == .controlling || phase == .suspended || (phase == .disconnecting && writeInFlight) }
  var isControlling: Bool { phase == .controlling && activeSurface != nil }
  var currentSurface: KeyboardTrackpadSurface? { activeSurface }
  func isControlling(owner: KeyboardTrackpadCaptureOwner) -> Bool {
    isControlling && activeOwner == owner
  }
  func isPending(owner: KeyboardTrackpadCaptureOwner) -> Bool { pendingOwner == owner }
  var isScrolling: Bool { scrollAxis != nil }
  var pointerActivity: String {
    if scrollDragging { return "Sideways drag" }
    if scrollAxis == .vertical { return "Vertical scroll" }
    return heldButtons == 0 ? "Pointer" : "Mouse drag"
  }
  var canTypeClipboard: Bool { canSendShortcut }
  var canSendShortcut: Bool {
    (phase == .connectedIdle || phase == .controlling) && !isShuttingDown && typingJob == nil && navigationJob == nil
  }

  var stateTitle: String {
    return switch phase {
    case .setupNeeded: "Setup needed"
    case .disconnected: "Disconnected"
    case .connecting: "Connecting"
    case .connectedIdle: "Connected · idle"
    case .controlling: "Controlling"
    case .suspended: "Suspended by phone"
    case .disconnecting: "Disconnecting"
    case .failed: "Connection failed"
    }
  }

  var stateDetail: String {
    if let failureMessage { return failureMessage }
    if isTypingClipboard { return "Typing clipboard · \(typingProgress) of \(typingLength) characters" }
    if targetPeer != nil, needsDeviceLink {
      if !pairedDevicesChecked { return "Checking whether this Mac is paired with the selected phone." }
      if !matchingPairedDevices.isEmpty {
        return "Choose Link device to confirm which paired Bluetooth device belongs to this aniCe phone."
      }
      if pairedDevicesChecked {
        return "Pair this phone with your Mac in Bluetooth Settings, then check again."
      }
      return "Pair this phone with your Mac in Bluetooth Settings, then link it once."
    }
    guard targetPeer != nil else {
      return trustedPeers.isEmpty ? "Pair a trusted Android phone in Devices to get started." : "Choose a trusted Android phone to get started."
    }
    return switch phase {
    case .setupNeeded: "Connect a paired phone, then click a surface to control it."
    case .disconnected: "Click Connect, or click the keyboard or pad to connect and control."
    case .connecting: "Authenticating the paired Bluetooth link and opening HID channels."
    case .connectedIdle: "Click the keyboard area or pad to start controlling the selected phone."
    case .controlling: "Input goes to the selected phone while this surface has focus."
    case .suspended: "The phone paused input. Control stays stopped when it resumes."
    case .disconnecting: "Releasing held input and closing this HID connection."
    case .failed: "Check the selected phone and Bluetooth pairing, then connect again."
    }
  }

  var featureSummary: String {
    guard let targetPeer else {
      if trustedPeers.isEmpty { return "Pair a trusted Android phone" }
      return "Choose a trusted phone"
    }
    return switch phase {
    case .connecting: "Connecting to \(targetPeer.deviceName)"
    case .connectedIdle: "Bluetooth HID ready · \(targetPeer.deviceName)"
    case .controlling: "Controlling \(targetPeer.deviceName)"
    case .suspended: "Input suspended · \(targetPeer.deviceName)"
    case .disconnecting: "Disconnecting from \(targetPeer.deviceName)"
    case .failed: "Bluetooth HID failed · \(targetPeer.deviceName)"
    case .disconnected, .setupNeeded: targetAddress == nil ? "Set up Bluetooth · \(targetPeer.deviceName)" : "Ready to connect · \(targetPeer.deviceName)"
    }
  }

  func updateTargets(_ peers: [DeviceIdentity], connectedPeerIDs: Set<String>, peerContextID: String?, connectedBLEPeerID: String? = nil) {
    let eligible = peers.filter { $0.platform == "android" }
    let previousKey = targetKey
    trustedPeers = eligible
    self.connectedBLEPeerID = connectedBLEPeerID
    self.connectedPeerIDs = Set(connectedPeerIDs.intersection(eligible.map(\.deviceId)))
    associationRevision &+= 1

    if let previousKey, !eligible.contains(where: { KeyboardTrackpadAssociations.peerKey($0) == previousKey }) {
      associations.prune(to: eligible)
      explicitSelectionWasRevoked = true
      retireCurrentTarget()
      targetPeer = nil
      phase = .setupNeeded
      notice = "The selected phone is no longer trusted. Choose another trusted phone to continue."
      return
    }
    if !isReady, phase != .connecting, phase != .disconnecting,
       lastDeliberatePeerKey == nil, !explicitSelectionWasRevoked,
       let ble = eligible.first(where: { $0.deviceId == connectedBLEPeerID && self.connectedPeerIDs.contains($0.deviceId) }) {
      if targetKey != KeyboardTrackpadAssociations.peerKey(ble) {
        targetPeer = ble
        failureMessage = nil
        automaticConnectionAttempts.removeAll(keepingCapacity: true)
      }
      resolveSetupPhase()
      return
    }
    if let previousKey, let updated = eligible.first(where: { KeyboardTrackpadAssociations.peerKey($0) == previousKey }) {
      targetPeer = updated
      resolveSetupPhase()
      return
    }
    guard targetPeer == nil, !explicitSelectionWasRevoked else { return }
    if let peerContextID, let contextual = eligible.first(where: { $0.deviceId == peerContextID }) {
      targetPeer = contextual
    } else if let lastDeliberatePeerKey, let deliberate = eligible.first(where: { KeyboardTrackpadAssociations.peerKey($0) == lastDeliberatePeerKey }) {
      targetPeer = deliberate
    } else {
      let connected = eligible.filter { self.connectedPeerIDs.contains($0.deviceId) }
      if connected.count == 1 { targetPeer = connected[0] }
      else if connected.count > 1, let lastDeliberatePeerKey,
              let deliberate = eligible.first(where: { KeyboardTrackpadAssociations.peerKey($0) == lastDeliberatePeerKey }) {
        targetPeer = deliberate
      }
    }
    resolveSetupPhase()
  }

  func selectTarget(_ peer: DeviceIdentity) {
    guard trustedPeers.contains(where: { $0 == peer }) else { return }
    explicitSelectionWasRevoked = false
    guard targetPeer != peer else { lastDeliberatePeerKey = KeyboardTrackpadAssociations.peerKey(peer); return }
    automaticConnectionAttempts.removeAll(keepingCapacity: true)
    lastDeliberatePeerKey = KeyboardTrackpadAssociations.peerKey(peer)
    relinkingAssociation = false
    let alreadyDisconnecting = phase == .disconnecting
    targetPeer = peer
    if !alreadyDisconnecting { retireCurrentTarget() }
    failureMessage = nil
    notice = nil
    associationRevision &+= 1
    if !alreadyDisconnecting { resolveSetupPhase() }
  }

  func enterPanel() {
    enterPanel(id: Self.legacyPresentationID)
  }

  func enterPanel(
    id presentationID: UUID,
    automaticallyConnect: Bool = true,
    refreshPairedDevices: Bool = true
  ) {
    let isFirstPresentation = panelRegistrations.isEmpty
    panelRegistrations[presentationID] = automaticallyConnect
    if isFirstPresentation { automaticConnectionAttempts.removeAll(keepingCapacity: true) }
    if refreshPairedDevices && (isFirstPresentation || !pairedDevicesChecked) {
      pairedDevicesChecked = false
      self.refreshPairedDevices()
    }
    connectAutomaticallyIfReady()
  }

  func refreshPairedDevices() {
    pairingRefreshGeneration &+= 1
    let refresh = pairingRefreshGeneration
    transport.pairedDevices { [weak self] devices in
      guard let self, !self.isShuttingDown, self.pairingRefreshGeneration == refresh else { return }
      var seenAddresses = Set<String>()
      self.pairedDevices = devices.compactMap { candidate in
        guard let address = AniCeHIDProtocol.normalizedAddress(candidate.address),
              seenAddresses.insert(address).inserted else { return nil }
        return PairedBluetoothDevice(address: address, name: candidate.name)
      }
      self.pairedDevicesChecked = true
      if let address = self.targetAddress, !self.pairedDevices.contains(where: { $0.address == address }) {
        self.notice = "The linked Bluetooth device is not currently paired. Pair it in Bluetooth Settings, then link it again."
        if self.isReady || self.phase == .connecting { self.disconnect() }
      }
      if let owner = self.pendingOwner, self.pendingCaptureSurface == nil {
        if self.canConnect {
          self.connect(arming: owner.surface)
        } else {
          self.pendingOwner = nil
          self.resolveSetupPhase()
        }
      } else {
        self.resolveSetupPhase()
      }
    }
  }

  @discardableResult func link(_ candidate: PairedBluetoothDevice, expectedPeerKey: String? = nil) -> Bool {
    if let expectedPeerKey, targetKey != expectedPeerKey {
      notice = "The selected phone changed. Confirm its Bluetooth device again."
      return false
    }
    guard phase == .setupNeeded || phase == .disconnected || phase == .failed else { return false }
    guard let targetPeer,
          pairedDevices.contains(where: { $0.address == candidate.address }),
          AniCeHIDProtocol.normalizedAddress(candidate.address) != nil else {
      notice = "That paired device is no longer available. Refresh the list and try again."
      refreshPairedDevices()
      return false
    }
    guard associations.associate(candidate.address, with: targetPeer) else {
      notice = "The Bluetooth address is invalid. Refresh the list and try again."
      return false
    }
    associationRevision &+= 1
    failureMessage = nil
    notice = "Bluetooth device linked. Connecting…"
    relinkingAssociation = false
    phase = .disconnected
    connectAutomaticallyIfReady()
    return true
  }

  func relinkBluetoothDevice() {
    guard targetPeer != nil else { return }
    automaticConnectionAttempts.removeAll(keepingCapacity: true)
    relinkingAssociation = true
    failureMessage = nil
    notice = "Choose and confirm the paired Bluetooth device for this trusted phone."
    if phase == .connecting || phase == .connectedIdle || phase == .controlling || phase == .suspended {
      disconnect()
    } else {
      resolveSetupPhase()
      refreshPairedDevices()
    }
  }

  func connect() { connect(arming: nil) }

  func requestControl(on surface: KeyboardTrackpadSurface) {
    requestControl(owner: surface == .keyboard ? Self.legacyKeyboardOwner : Self.legacyPadOwner)
  }

  func requestControl(owner: KeyboardTrackpadCaptureOwner) {
    guard !isShuttingDown, typingJob == nil, navigationJob == nil,
          panelRegistrations[owner.presentationID] != nil || owner.presentationID == Self.legacyPresentationID else { return }
    if activeOwner != nil && activeOwner != owner { finishCapture() }
    if phase == .connecting {
      pendingCaptureSurface = owner.surface
      pendingOwner = owner
      return
    }
    if phase == .connectedIdle {
      captureEpoch &+= 1
      activeSurface = owner.surface
      activeOwner = owner
      pendingCaptureSurface = nil
      pendingOwner = nil
      phase = .controlling
      notice = nil
      return
    }
    guard phase == .disconnected || phase == .setupNeeded || phase == .failed else { return }
    pendingOwner = owner
    connect(arming: owner.surface)
  }

  func toggleControl(owner: KeyboardTrackpadCaptureOwner) {
    if activeOwner == owner || pendingOwner == owner {
      stopControl(owner: owner)
    } else {
      requestControl(owner: owner)
    }
  }

  func stopControl(owner: KeyboardTrackpadCaptureOwner) {
    if pendingOwner == owner { pendingOwner = nil; pendingCaptureSurface = nil }
    guard activeOwner == owner else { return }
    cancelTyping(interrupted: true)
    finishCapture()
  }

  func stopControl(presentationID: UUID) {
    if let pendingOwner, pendingOwner.presentationID == presentationID { stopControl(owner: pendingOwner) }
    if let activeOwner, activeOwner.presentationID == presentationID { stopControl(owner: activeOwner) }
  }

  func surfaceLost(_ surface: KeyboardTrackpadSurface) {
    surfaceLost(owner: surface == .keyboard ? Self.legacyKeyboardOwner : Self.legacyPadOwner)
  }

  func surfaceLost(owner: KeyboardTrackpadCaptureOwner) {
    if pendingOwner == owner { pendingOwner = nil; pendingCaptureSurface = nil }
    if activeOwner == owner {
      cancelTyping(interrupted: true)
      finishCapture()
    }
  }

  func keyDown(usage: UInt8, modifiers: UInt8, owner: KeyboardTrackpadCaptureOwner? = nil) {
    guard phase == .controlling, activeSurface == .keyboard, owner == nil || activeOwner == owner,
          usage > 0, typingJob == nil else { return }
    heldModifiers = modifiers
    if heldUsages.contains(usage) { return }
    guard heldUsages.count < 6 else {
      stopForOverflow()
      return
    }
    heldUsages.append(usage)
    enqueue(.keyboard(heldModifiers, heldUsages))
  }

  func keyUp(usage: UInt8, modifiers: UInt8, owner: KeyboardTrackpadCaptureOwner? = nil) {
    guard phase == .controlling, activeSurface == .keyboard, owner == nil || activeOwner == owner,
          typingJob == nil else { return }
    heldModifiers = modifiers
    heldUsages.removeAll { $0 == usage }
    enqueue(.keyboard(heldModifiers, heldUsages))
  }

  func modifiersChanged(_ modifiers: UInt8, owner: KeyboardTrackpadCaptureOwner? = nil) {
    guard phase == .controlling, activeSurface == .keyboard, owner == nil || activeOwner == owner,
          typingJob == nil,
          heldModifiers != modifiers else { return }
    heldModifiers = modifiers
    enqueue(.keyboard(heldModifiers, heldUsages))
  }

  func pointerButtonDown(secondary: Bool = false, owner: KeyboardTrackpadCaptureOwner? = nil) {
    guard phase == .controlling, activeSurface == .pad, owner == nil || activeOwner == owner,
          typingJob == nil else { return }
    heldButtons = secondary ? 2 : 1
    enqueue(.mouse(heldButtons, 0, 0, 0))
  }

  func pointerButtonUp(owner: KeyboardTrackpadCaptureOwner? = nil) {
    guard phase == .controlling, activeSurface == .pad, owner == nil || activeOwner == owner,
          typingJob == nil else { return }
    heldButtons = 0
    enqueue(.mouse(0, 0, 0, 0))
  }

  func pointerMoved(deltaX: Double, deltaY: Double, owner: KeyboardTrackpadCaptureOwner? = nil) {
    guard phase == .controlling, activeSurface == .pad, owner == nil || activeOwner == owner,
          typingJob == nil,
          deltaX.isFinite, deltaY.isFinite, deltaX != 0 || deltaY != 0 else { return }
    enqueueMotion(buttons: heldButtons, x: deltaX * pointerSpeed.scale, y: deltaY * pointerSpeed.scale, wheel: 0)
  }

  func scroll(deltaY: Double, precise: Bool, owner: KeyboardTrackpadCaptureOwner? = nil) {
    guard phase == .controlling, activeSurface == .pad, owner == nil || activeOwner == owner,
          typingJob == nil,
          reportProtocol, deltaY.isFinite, deltaY != 0 else { return }
    let wheel = (precise ? deltaY / 12.0 : deltaY) * scrollSpeed.scale
    enqueueMotion(buttons: heldButtons, x: 0, y: 0, wheel: wheel)
  }

  func scrollGesture(deltaX: Double, deltaY: Double, phase: NSEvent.Phase, precise: Bool, momentum: Bool,
    owner: KeyboardTrackpadCaptureOwner? = nil) {
    guard isControlling, activeSurface == .pad, owner == nil || activeOwner == owner, !momentum,
          deltaX.isFinite, deltaY.isFinite, heldButtons == 0 || scrollDragging else { return }
    if phase.contains(.cancelled) { cancelScrollGesture(owner: owner); return }
    if phase.isEmpty {
      if scrollAxis == nil { scroll(deltaY: deltaY, precise: precise, owner: owner) }
      return
    }
    if phase.contains(.began) {
      cancelScrollGesture(owner: owner)
      scrollAxis = .undecided
    }
    guard let axis = scrollAxis else { return }
    scrollX += deltaX; scrollY += deltaY
    var x = deltaX, y = deltaY
    if axis == .undecided, max(abs(scrollX), abs(scrollY)) >= 6 {
      scrollAxis = abs(scrollX) > abs(scrollY) ? .horizontal : .vertical
      x = scrollX; y = scrollY
    }
    if scrollAxis == .vertical {
      scroll(deltaY: y, precise: precise, owner: owner)
    } else if scrollAxis == .horizontal {
      if !scrollDragging, abs(scrollX) >= 12 {
        pointerButtonDown(owner: owner)
        scrollDragging = true
        x = scrollX
      }
      if scrollDragging { pointerMoved(deltaX: x, deltaY: 0, owner: owner) }
    }
    if phase.contains(.ended) { cancelScrollGesture(owner: owner) }
  }

  func cancelScrollGesture(owner: KeyboardTrackpadCaptureOwner? = nil) {
    guard owner == nil || activeOwner == owner else { return }
    if scrollDragging { pointerButtonUp(owner: owner) }
    scrollDragging = false
    scrollAxis = nil
    scrollX = 0; scrollY = 0
  }

  func sendTap(usage: UInt8) {
    guard canSendShortcut, usage > 0 else { return }
    startTypingJob([KeyboardTrackpadKeyStroke(usage: usage, modifiers: 0)], clipboard: false)
  }

  func sendRecentApps() {
    guard canSendShortcut else { return }
    startKeyboardSequence([
      KeyboardStep(modifiers: 0, usages: [], delay: .zero),
      KeyboardStep(modifiers: 8, usages: [], delay: .milliseconds(35)),
      KeyboardStep(modifiers: 8, usages: [0x2B], delay: .milliseconds(50)),
      KeyboardStep(modifiers: 8, usages: [], delay: .milliseconds(20)),
      KeyboardStep(modifiers: 0, usages: [], delay: .zero)
    ], clipboard: false, characterCount: 0)
  }

  func sendNavigation(usage: UInt16) {
    guard canSendShortcut, reportProtocol else {
      notice = reportProtocol ? "Connect the selected phone before using navigation." : "Phone navigation needs HID report protocol."
      return
    }
    finishCapture()
    nextNavigationID &+= 1
    let jobID = nextNavigationID
    navigationJob = NavigationJob(id: jobID, usage: usage)
    enqueueIdle(.navigation(usage, true), completion: { [weak self] result in
      self?.navigationPressCompleted(jobID: jobID, result: result)
    })
  }

  func stopControlling() {
    cancelTyping(interrupted: true)
    finishCapture()
  }

  func shutdown() {
    guard !isShuttingDown else { return }
    cancelNavigation()
    cancelTyping(interrupted: false)
    finishCapture()
    navigationTimer?.cancel()
    isShuttingDown = true
    motionTimer?.cancel()
    typingTimer?.cancel()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    sleepObserver = nil
    transport.shutdown()
  }

  func disconnect() {
    if let targetKey, let address = targetAddress {
      automaticConnectionAttempts.insert(targetKey + "|" + address)
    }
    guard phase != .disconnecting else { return }
    cancelNavigation()
    cancelTyping(interrupted: true)
    if phase == .connecting {
      connectionGeneration &+= 1
      let operation = connectionGeneration
      pendingCaptureSurface = nil
      pendingOwner = nil
      activeSurface = nil
      activeOwner = nil
      phase = .disconnecting
      transport.disconnect { [weak self] in
        guard let self, !self.isShuttingDown, self.connectionGeneration == operation else { return }
        self.phase = .disconnected
        self.resolveSetupPhase()
      }
      return
    }
    retireConnection()
  }

  func leavePanel() { leavePanel(id: Self.legacyPresentationID) }

  func leavePanel(id presentationID: UUID) {
    panelRegistrations.removeValue(forKey: presentationID)
    if pendingOwner?.presentationID == presentationID { pendingOwner = nil; pendingCaptureSurface = nil }
    if activeOwner?.presentationID == presentationID { finishCapture() }
  }

  func applicationWasInterrupted() {
    cancelTyping(interrupted: true)
    finishCapture()
  }

  func systemWillSleep() {
    cancelNavigation()
    cancelTyping(interrupted: true)
    retireConnection()
  }

  func trustWasRemoved(retaining peers: [DeviceIdentity]) {
    associations.prune(to: peers.filter { $0.platform == "android" })
    updateTargets(peers, connectedPeerIDs: connectedPeerIDs, peerContextID: nil, connectedBLEPeerID: connectedBLEPeerID)
  }

  func identityWasReset() {
    cancelNavigation()
    cancelTyping(interrupted: true)
    associations.clear()
    associationRevision &+= 1
    explicitSelectionWasRevoked = true
    targetPeer = nil
    retireConnection()
    phase = .setupNeeded
  }

  func deviceWasDisconnected(_ peer: DeviceIdentity) {
    guard targetPeer.map(KeyboardTrackpadAssociations.peerKey) == KeyboardTrackpadAssociations.peerKey(peer) else { return }
    disconnect()
  }

  func stopTyping() { cancelTyping(interrupted: true) }

  func typeClipboard() {
    guard canTypeClipboard else {
      notice = "Connect the selected phone and wait for the current action to finish before typing clipboard text."
      return
    }
    // This is the only pasteboard read in the feature; it happens only after an explicit click.
    guard let text = NSPasteboard.general.string(forType: .string) else {
      notice = "The Mac clipboard does not contain plain text."
      return
    }
    typeClipboardSnapshot(text)
  }

  func typeClipboardSnapshot(_ text: String) {
    guard canTypeClipboard else { return }
    switch Self.clipboardKeyStrokes(text) {
    case .success(let keys):
      startTypingJob(keys, clipboard: true)
    case .failure(.empty): notice = "The Mac clipboard is empty."
    case .failure(.tooLong): notice = "Clipboard typing is limited to 1,024 characters. Nothing was sent."
    case .failure(.unsupported(let scalar)):
      notice = String(format: "Clipboard text contains unsupported character U+%04X. Nothing was sent.", scalar)
    }
  }

  static func clipboardKeyStrokes(_ text: String) -> Result<[KeyboardTrackpadKeyStroke], ClipboardTypingValidationError> {
    var strokes: [KeyboardTrackpadKeyStroke] = []
    var previousWasCR = false
    for scalar in text.unicodeScalars {
      if scalar.value == 10 && previousWasCR { previousWasCR = false; continue }
      previousWasCR = scalar.value == 13
      let value = previousWasCR ? 10 : scalar.value
      guard strokes.count < 1_024 else { return .failure(.tooLong) }
      guard value == 9 || value == 10 || (value >= 0x20 && value <= 0x7E),
            let key = AniCeHIDProtocol.key(forASCIICharacter: unichar(value)), key.count == 2 else {
        return .failure(.unsupported(value))
      }
      strokes.append(KeyboardTrackpadKeyStroke(usage: key[0].uint8Value, modifiers: key[1].uint8Value))
    }
    return strokes.isEmpty ? .failure(.empty) : .success(strokes)
  }

  private func connect(arming surface: KeyboardTrackpadSurface?) {
    guard phase == .setupNeeded || phase == .disconnected || phase == .failed else { return }
    guard !relinkingAssociation else { return }
    guard targetPeer != nil, let address = targetAddress else {
      pendingCaptureSurface = nil
      pendingOwner = nil
      phase = .setupNeeded
      notice = "Choose a trusted aniCe phone and link its paired Bluetooth device first."
      return
    }
    guard pairedDevicesChecked else {
      pendingCaptureSurface = nil
      refreshPairedDevices()
      phase = .setupNeeded
      notice = "Checking the linked Bluetooth pairing."
      return
    }
    guard pairedDevices.contains(where: { $0.address == address }) else {
      pendingCaptureSurface = nil
      pendingOwner = nil
      phase = .setupNeeded
      notice = "This Mac no longer has the linked Bluetooth pairing. Pair the phone in Bluetooth Settings, then link it again."
      refreshPairedDevices()
      return
    }
    connectionGeneration &+= 1
    let operation = connectionGeneration
    pendingCaptureSurface = surface
    if surface == nil { pendingOwner = nil }
    phase = .connecting
    failureMessage = nil
    notice = nil
    transport.connect(address: address, generation: operation) { [weak self] result in
      guard let self, !self.isShuttingDown, self.connectionGeneration == operation else { return }
      switch result {
      case .success:
        self.failureMessage = nil
        if let surface = self.pendingCaptureSurface,
           let owner = self.pendingOwner,
           self.panelRegistrations[owner.presentationID] != nil || owner.presentationID == Self.legacyPresentationID {
          self.pendingCaptureSurface = nil
          self.pendingOwner = nil
          self.captureEpoch &+= 1
          self.activeSurface = surface
          self.activeOwner = owner
          self.phase = .controlling
        } else if self.activeOwner != nil, self.activeSurface != nil {
          // Readiness can arrive before connect() completes and a fresh click can arm the live link.
          self.pendingCaptureSurface = nil
          self.pendingOwner = nil
          self.phase = .controlling
        } else {
          self.pendingCaptureSurface = nil
          self.pendingOwner = nil
          self.activeSurface = nil
          self.activeOwner = nil
          self.phase = .connectedIdle
        }
      case .failure(let message):
        self.pendingCaptureSurface = nil
        self.pendingOwner = nil
        self.phase = .failed
        self.failureMessage = message
        self.activeSurface = nil
        self.activeOwner = nil
      }
    }
  }

  private func finishCapture() {
    cancelNavigation()
    let hadCapture = activeSurface != nil || !heldUsages.isEmpty || heldButtons != 0 || heldModifiers != 0
    pendingCaptureSurface = nil
    pendingOwner = nil
    guard hadCapture else { return }
    let endedSurface = activeSurface
    motionTimer?.cancel(); motionTimer = nil
    lastMotionWrite = nil
    activeSurface = nil
    activeOwner = nil
    captureEpoch &+= 1
    let needsKeyboardRelease = endedSurface == .keyboard || !heldUsages.isEmpty || heldModifiers != 0 || typeKeyDown
    let needsMouseRelease = endedSurface == .pad || heldButtons != 0
    heldUsages.removeAll(keepingCapacity: true)
    scrollDragging = false; scrollAxis = nil; scrollX = 0; scrollY = 0
    heldModifiers = 0
    heldButtons = 0
    outputQueue.removeAll { !$0.release }
    if needsKeyboardRelease { appendPrivileged(.keyboard(0, [])) }
    if needsMouseRelease { appendPrivileged(.mouse(0, 0, 0, 0)) }
    if phase == .controlling { phase = .connectedIdle }
    drainOutput()
  }

  private func stopForOverflow() {
    notice = "Input paused because too many key transitions queued. Held input was released; click the surface to resume."
    finishCapture()
  }

  private func enqueue(_ payload: Output.Payload) {
    guard phase == .controlling, outputQueue.count < 128 else {
      if phase == .controlling { stopForOverflow() }
      return
    }
    outputQueue.append(Output(generation: connectionGeneration, captureEpoch: captureEpoch, payload: payload))
    drainOutput()
  }

  private func enqueueIdle(_ payload: Output.Payload, completion: KeyboardTrackpadResultCompletion? = nil) {
    guard (phase == .connectedIdle || phase == .controlling), outputQueue.count < 128 else { return }
    outputQueue.append(Output(generation: connectionGeneration, captureEpoch: captureEpoch, payload: payload,
      idleAllowed: true, completion: completion))
    drainOutput()
  }

  private func appendPrivileged(_ payload: Output.Payload) {
    guard !outputQueue.contains(where: { $0.release && $0.payload == payload }) else { return }
    outputQueue.append(Output(generation: connectionGeneration, captureEpoch: captureEpoch, payload: payload, release: true))
  }

  private func enqueueMotion(buttons: UInt8, x: Double, y: Double, wheel: Double) {
    if let last = outputQueue.indices.last,
       case .motion(let existingButtons, let oldX, let oldY, let oldWheel) = outputQueue[last].payload,
       existingButtons == buttons, outputQueue[last].generation == connectionGeneration,
       outputQueue[last].captureEpoch == captureEpoch {
      outputQueue[last].payload = .motion(buttons, Self.bounded(oldX + x, -512, 512), Self.bounded(oldY + y, -512, 512), Self.bounded(oldWheel + wheel, -32, 32))
    } else {
      guard outputQueue.count < 128 else { stopForOverflow(); return }
      outputQueue.append(Output(generation: connectionGeneration, captureEpoch: captureEpoch,
        payload: .motion(buttons, Self.bounded(x, -512, 512), Self.bounded(y, -512, 512), Self.bounded(wheel, -32, 32))))
    }
    drainOutput()
  }

  private static func bounded(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }

  private func drainOutput() {
    guard !writeInFlight, !isShuttingDown else { return }
    while let first = outputQueue.first {
      guard first.generation == connectionGeneration, first.release || first.captureEpoch == captureEpoch else {
        outputQueue.removeFirst()
        continue
      }
      guard phase == .controlling || phase == .disconnecting || first.release || (first.idleAllowed && (phase == .connectedIdle || phase == .controlling)) else {
        outputQueue.removeFirst()
        continue
      }
      if case .motion(let buttons, let x, let y, let wheel) = first.payload {
        let dx = Self.reportDelta(x, limit: 127), dy = Self.reportDelta(y, limit: 127), wh = Self.reportDelta(wheel, limit: 8)
        if dx == 0 && dy == 0 && wh == 0 {
          guard outputQueue.count > 1 else { return }
          outputQueue.removeFirst()
          continue
        }
        let now = ContinuousClock.now
        if let lastMotionWrite {
          let earliest = lastMotionWrite + .nanoseconds(1_000_000_000 / 60)
          if now < earliest {
            guard motionTimer == nil else { return }
            motionTimer = Task { [weak self] in
              try? await Task.sleep(until: earliest, clock: .continuous)
              guard let self, !Task.isCancelled else { return }
              self.motionTimer = nil
              self.drainOutput()
            }
            return
          }
        }
        let remainderX = x - Double(dx), remainderY = y - Double(dy), remainderWheel = wheel - Double(wh)
        outputQueue.removeFirst()
        if remainderX != 0 || remainderY != 0 || remainderWheel != 0 {
          outputQueue.insert(Output(generation: first.generation, captureEpoch: first.captureEpoch,
            payload: .motion(buttons, remainderX, remainderY, remainderWheel)), at: 0)
        }
        lastMotionWrite = now
        send(.mouse(buttons, dx, dy, wh), generation: first.generation)
        return
      }
      outputQueue.removeFirst()
      send(first.payload, generation: first.generation, completion: first.completion)
      return
    }
    if typingJob != nil { advanceTyping() }
    else if pendingDisconnect && !disconnectStarted {
      disconnectStarted = true
      let operation = connectionGeneration
      transport.disconnect { [weak self] in
        guard let self else { return }
        self.disconnectStarted = false
        if self.connectionGeneration == operation {
          self.pendingDisconnect = false
          self.navigationTimer?.cancel(); self.navigationTimer = nil
          self.navigationJob = nil
          if !self.isShuttingDown {
            self.phase = .disconnected
            self.resolveSetupPhase()
          }
        } else {
          self.drainOutput()
        }
      }
    }
  }

  private static func reportDelta(_ value: Double, limit: Int) -> Int {
    let truncated = value.rounded(.towardZero)
    return Int(max(Double(-limit), min(Double(limit), truncated)))
  }

  private func send(_ payload: Output.Payload, generation: UInt64, completion onComplete: KeyboardTrackpadResultCompletion? = nil) {
    guard generation == connectionGeneration else { drainOutput(); return }
    writeInFlight = true
    nextWriteID &+= 1
    let writeID = nextWriteID
    let epoch = captureEpoch
    let completion: KeyboardTrackpadResultCompletion = { [weak self] result in
      guard let self, self.nextWriteID == writeID else { return }
      self.writeInFlight = false
      guard generation == self.connectionGeneration else {
        onComplete?(.failure("Input ended before the report completed."))
        self.drainOutput()
        return
      }
      guard self.phase != .suspended else {
        onComplete?(.failure("The phone suspended HID input."))
        return
      }
      // Ending capture invalidates input, not a failure of the same Bluetooth connection.
      if case .failure(let message) = result {
        self.failTransport(message)
        onComplete?(.failure(message))
        return
      }
      guard epoch == self.captureEpoch else {
        onComplete?(.failure("Input ended before the report completed."))
        self.drainOutput()
        return
      }
      onComplete?(.success)
      self.drainOutput()
    }
    switch payload {
    case .keyboard(let modifiers, let usages): transport.keyboard(modifiers: modifiers, usages: usages, completion: completion)
    case .mouse(let buttons, let dx, let dy, let wheel): transport.mouse(buttons: buttons, deltaX: dx, deltaY: dy, wheel: wheel, completion: completion)
    case .navigation(let usage, let pressed): transport.navigation(usage: usage, pressed: pressed, completion: completion)
    case .motion: assertionFailure("Motion must be reduced to a bounded report before sending.")
    }
  }

  private func startTypingJob(_ keys: [KeyboardTrackpadKeyStroke], clipboard: Bool) {
    let steps = keys.enumerated().flatMap { index, key in
      [KeyboardStep(modifiers: key.modifiers, usages: [key.usage], delay: .milliseconds(50)),
       KeyboardStep(modifiers: 0, usages: [], delay: .milliseconds(50), completedCharacters: index + 1)]
    }
    startKeyboardSequence(steps, clipboard: clipboard, characterCount: keys.count)
  }

  private func startKeyboardSequence(_ steps: [KeyboardStep], clipboard: Bool, characterCount: Int) {
    guard !steps.isEmpty, (phase == .connectedIdle || phase == .controlling), typingJob == nil, navigationJob == nil else { return }
    finishCapture()
    nextTypingID &+= 1
    typingJob = TypingJob(id: nextTypingID, steps: steps, clipboard: clipboard)
    isTypingClipboard = clipboard
    typingProgress = 0
    typingLength = characterCount
    typeKeyDown = false
    notice = nil
    drainOutput()
  }

  private func navigationPressCompleted(jobID: UInt64, result: KeyboardTrackpadTransportResult) {
    guard var job = navigationJob, job.id == jobID else { return }
    guard case .success = result else {
      navigationTimer?.cancel()
      navigationTimer = nil
      navigationJob = nil
      return
    }
    if job.stage == .releaseWhenPressed {
      enqueueNavigationRelease(jobID: jobID)
      return
    }
    guard job.stage == .pressPending else { return }
    job.stage = .holding
    navigationJob = job
    navigationTimer = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(35))
      guard let self, !Task.isCancelled,
            let current = self.navigationJob, current.id == jobID, current.stage == .holding else { return }
      self.navigationTimer = nil
      self.enqueueNavigationRelease(jobID: jobID)
    }
  }

  private func enqueueNavigationRelease(jobID: UInt64) {
    guard var job = navigationJob, job.id == jobID,
          job.stage == .holding || job.stage == .releaseWhenPressed else { return }
    navigationTimer?.cancel()
    navigationTimer = nil
    job.stage = .releasePending
    navigationJob = job
    outputQueue.insert(Output(
      generation: connectionGeneration, captureEpoch: captureEpoch,
      payload: .navigation(job.usage, false), idleAllowed: true, release: true,
      completion: { [weak self] _ in
        guard let self, self.navigationJob?.id == jobID else { return }
        self.navigationJob = nil
        self.drainOutput()
      }
    ), at: 0)
    drainOutput()
  }

  private func cancelNavigation() {
    guard var job = navigationJob else { return }
    navigationTimer?.cancel()
    navigationTimer = nil
    switch job.stage {
    case .pressPending:
      job.stage = .releaseWhenPressed
      navigationJob = job
    case .holding:
      enqueueNavigationRelease(jobID: job.id)
    case .releasePending, .releaseWhenPressed:
      break
    }
  }

  private func advanceTyping() {
    guard !writeInFlight, var job = typingJob, !job.waiting else { return }
    if job.index >= job.steps.count {
      typingJob = nil
      isTypingClipboard = false
      typingProgress = typingLength
      notice = job.clipboard ? "Clipboard text submitted. Check the phone to confirm it appeared." : nil
      return
    }
    let step = job.steps[job.index], jobID = job.id
    job.waiting = true
    typingJob = job
    let pressed = step.modifiers != 0 || !step.usages.isEmpty
    if pressed { typeKeyDown = true }
    send(.keyboard(step.modifiers, step.usages), generation: connectionGeneration) { [weak self] result in
      guard let self, self.typingJob?.id == jobID, case .success = result else { return }
      if !pressed { self.typeKeyDown = false }
      self.typingTimer = Task { [weak self] in
        try? await Task.sleep(for: step.delay)
        guard let self, !Task.isCancelled, var current = self.typingJob, current.id == jobID else { return }
        self.typingTimer = nil
        current.index += 1
        current.waiting = false
        if let progress = step.completedCharacters { self.typingProgress = progress }
        self.typingJob = current
        self.advanceTyping()
      }
    }
  }

  private func cancelTyping(interrupted: Bool) {
    guard let job = typingJob else { return }
    typingTimer?.cancel(); typingTimer = nil
    typingJob = nil
    isTypingClipboard = false
    if typeKeyDown {
      typeKeyDown = false
      outputQueue.insert(Output(generation: connectionGeneration, captureEpoch: captureEpoch, payload: .keyboard(0, []), release: true), at: 0)
    }
    if interrupted && job.clipboard { notice = "Typing stopped. Check the phone before trying again." }
    drainOutput()
  }

  private func failTransport(_ message: String) {
    writeInFlight = false
    connectionGeneration &+= 1
    if isTypingClipboard { notice = "Typing stopped. Check the phone before trying again." }
    discardPendingInput()
    phase = .failed
    failureMessage = message
    transport.disconnect {}
  }

  private func discardPendingInput() {
    captureEpoch &+= 1
    outputQueue.removeAll()
    typingTimer?.cancel(); typingTimer = nil
    navigationTimer?.cancel(); navigationTimer = nil
    motionTimer?.cancel(); motionTimer = nil
    lastMotionWrite = nil
    typingJob = nil
    navigationJob = nil
    isTypingClipboard = false
    activeSurface = nil
    pendingCaptureSurface = nil
    activeOwner = nil
    pendingOwner = nil
    heldUsages.removeAll(); heldModifiers = 0; heldButtons = 0; typeKeyDown = false
    scrollDragging = false; scrollAxis = nil; scrollX = 0; scrollY = 0
  }

  private func transportChanged(_ event: KeyboardTrackpadTransportEvent) {
    guard !isShuttingDown else { return }
    switch event {
    case .changed(let generation, let ready, let suspended, let reportProtocol, let message):
      guard generation == connectionGeneration else { return }
      self.reportProtocol = reportProtocol
      if suspended && ready {
        if isTypingClipboard { notice = "Typing stopped. Check the phone before trying again." }
        discardPendingInput()
        phase = .suspended
        failureMessage = nil
      } else if ready {
        if phase != .disconnecting { phase = activeSurface == nil ? .connectedIdle : .controlling }
        failureMessage = nil
      } else if phase != .connecting && phase != .disconnecting {
        if phase == .connectedIdle || phase == .controlling || phase == .suspended {
          if isTypingClipboard { notice = "Typing stopped. Check the phone before trying again." }
          discardPendingInput()
          connectionGeneration &+= 1
          phase = .failed
          failureMessage = message ?? "Bluetooth HID disconnected. Reconnect manually; input was not replayed."
        }
      }
    }
  }

  private func retireConnection() {
    cancelNavigation()
    let wasConnecting = phase == .connecting
    let hadReadyLink = phase == .connectedIdle || phase == .controlling || phase == .suspended
    if hadReadyLink { finishCapture() }
    connectionGeneration &+= 1
    let operation = connectionGeneration
    outputQueue = outputQueue.map {
      Output(generation: operation, captureEpoch: captureEpoch, payload: $0.payload,
        idleAllowed: $0.idleAllowed, release: $0.release)
    }
    pendingCaptureSurface = nil
    pendingOwner = nil
    if hadReadyLink {
      phase = .disconnecting
      pendingDisconnect = true
      disconnectStarted = false
      drainOutput()
    } else {
      phase = .disconnecting
      transport.disconnect { [weak self] in
        guard let self, !self.isShuttingDown, self.connectionGeneration == operation else { return }
        self.navigationTimer?.cancel(); self.navigationTimer = nil
        self.navigationJob = nil
        self.phase = .disconnected
        self.resolveSetupPhase()
      }
    }
    if wasConnecting { activeSurface = nil; activeOwner = nil }
  }

  private func retireCurrentTarget() {
    cancelTyping(interrupted: true)
    retireConnection()
  }

  private func resolveSetupPhase() {
    guard !isReady, phase != .connecting, phase != .disconnecting else { return }
    if targetPeer == nil || needsDeviceLink { phase = .setupNeeded }
    else if phase != .failed { phase = .disconnected }
    connectAutomaticallyIfReady()
  }

  private func connectAutomaticallyIfReady() {
    guard panelRegistrations.values.contains(true), canConnect,
          let targetPeer, let address = targetAddress else { return }
    let token = KeyboardTrackpadAssociations.peerKey(targetPeer) + "|" + address
    guard automaticConnectionAttempts.insert(token).inserted else { return }
    connect()
  }

  private func installLifecycleObservers() {
    let center = NotificationCenter.default
    let stopNames: [Notification.Name] = [
      NSApplication.didResignActiveNotification,
      NSMenu.didBeginTrackingNotification,
      NSPopover.willShowNotification,
      NSWindow.willBeginSheetNotification
    ]
    for name in stopNames {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.applicationWasInterrupted() }
      })
    }
    sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.systemWillSleep() } }
    observers.append(center.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshPairedDevices() } })
  }
}
