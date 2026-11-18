// SPDX-License-Identifier: GPL-3.0-or-later
// Owns bounded discovery presentation and stops discovery on sleep or termination.
import AppKit
import Observation

@Observable @MainActor
final class MacDiscoveryModel {
  var beforeStart: () -> Void = {}
  var afterStop: () -> Void = {}
  let adapter: any PairingPeripheralAdapter
  let session: PeripheralDiscoverySession
  private(set) var nearbyAvailable = false
  @ObservationIgnored private var deadlineTask: Task<Void, Never>?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  init(
    adapter: any PairingPeripheralAdapter = CoreBluetoothPeripheralAdapter(),
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.adapter = adapter
    session = PeripheralDiscoverySession(now: now, makeAdapter: { adapter })
    session.onChange = { [weak self] in self?.scheduleNearbyDeadline() }
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
  }
  func start() {
    nearbyAvailable = false
    deadlineTask?.cancel()
    beforeStart()
    timer?.invalidate()
    session.start()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.session.tick()
        if !self.session.active {
          self.timer?.invalidate()
          self.timer = nil
          self.afterStop()
        }
      }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  func stop() {
    nearbyAvailable = false
    deadlineTask?.cancel()
    deadlineTask = nil
    let wasActive = session.active
    timer?.invalidate()
    timer = nil
    session.stop()
    if wasActive { afterStop() }
  }
  /// Explicit first-setup availability uses the existing radio, with pairing writes still closed.
  func startNearby() {
    beforeStart()
    timer?.invalidate()
    timer = nil
    deadlineTask?.cancel()
    nearbyAvailable = true
    session.start(nearbyAvailability: true)
    scheduleNearbyDeadline()
  }
  private func scheduleNearbyDeadline() {
    guard nearbyAvailable else { return }
    deadlineTask?.cancel()
    deadlineTask = nil
    guard session.active else {
      nearbyAvailable = false
      afterStop()
      return
    }
    guard let deadline = session.nextDeadline else { return }
    deadlineTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0.001, deadline - ProcessInfo.processInfo.systemUptime))) }
      catch { return }
      guard let self, self.nearbyAvailable else { return }
      self.session.tick()
    }
  }
  func openSettings() {
    let target =
      session.state == .bluetoothOff
      ? "com.apple.Bluetooth" : "com.apple.preference.security?Privacy_Bluetooth"
    if let url = URL(string: "x-apple.systempreferences:" + target) { NSWorkspace.shared.open(url) }
  }
}
