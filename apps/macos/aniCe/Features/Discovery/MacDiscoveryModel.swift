// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation

@Observable @MainActor
final class MacDiscoveryModel {
    let session = PeripheralDiscoverySession(makeAdapter: { CoreBluetoothPeripheralAdapter() })
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    init() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
    }
    func start() {
        timer?.invalidate(); session.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.session.tick()
                if !self.session.active { self.timer?.invalidate(); self.timer = nil }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil; session.stop() }
    func openSettings() {
        let target = session.state == .bluetoothOff ? "com.apple.Bluetooth" : "com.apple.preference.security?Privacy_Bluetooth"
        if let url = URL(string: "x-apple.systempreferences:" + target) { NSWorkspace.shared.open(url) }
    }
}
