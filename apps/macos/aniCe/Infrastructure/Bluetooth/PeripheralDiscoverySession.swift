// SPDX-License-Identifier: GPL-3.0-or-later
// Owns bounded peripheral publication, nonce rotation and stale-callback rejection.
import Foundation
import Observation
import Security

/// Framework-free events keep timing and stale-operation rules deterministic in tests.
enum PeripheralEvent { case permissionPending, initializing, available, off, denied, unsupported, resetting, published, advertising, failure }
enum DiscoveryRecovery { case none, retry, bluetoothSettings, permissionSettings, unsupported }
enum DiscoveryRead: Equatable { case value(Data), unavailable, invalidOffset, unknownCharacteristic }
@MainActor protocol PeripheralAdapter: AnyObject {
    func begin(event: @escaping (PeripheralEvent) -> Void, read: @escaping (Bool, Int) -> DiscoveryRead)
    func publish()
    func advertise()
    func stop()
}

@Observable @MainActor
final class PeripheralDiscoverySession {
    private(set) var state: DiscoveryState = .idle
    private(set) var recovery: DiscoveryRecovery = .none
    private(set) var message = "Let your nearby Android device find this Mac. Discovery does not pair devices."
    private(set) var remainingSeconds = 0
    private(set) var active = false
    private var generation = 0
    private var adapter: (any PeripheralAdapter)?
    private var payload: Data?
    private var startupDeadline: TimeInterval?
    private var deadline: TimeInterval?
    private var nextRotation: TimeInterval?
    private var publishing = false
    private var awaitingAdvertising = false
    private let now: () -> TimeInterval
    private let random: () throws -> Data
    private let makeAdapter: () -> any PeripheralAdapter

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         random: @escaping () throws -> Data = PeripheralDiscoverySession.secureNonce,
         makeAdapter: @escaping () -> any PeripheralAdapter) {
        self.now = now; self.random = random; self.makeAdapter = makeAdapter
    }

    nonisolated static func secureNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BlePayloadCodec.Failure.length
        }
        return Data(bytes)
    }

    func start() {
        stop()
        generation += 1
        let operation = generation
        active = true; state = .discovering; message = "Starting Bluetooth discovery…"
        // Authorization dialogs have no watchdog. The adapter reports when authorization resolves.
        let transport = makeAdapter(); adapter = transport
        transport.begin(event: { [weak self] event in
            guard let self, self.generation == operation, self.active else { return }
            self.receive(event)
        }, read: { [weak self] matches, offset in
            guard let self, self.generation == operation else { return .unavailable }
            return self.read(matches: matches, offset: offset)
        })
    }

    func stop(message: String = "Discovery stopped. Start again when you are ready.") {
        generation += 1; active = false
        adapter?.stop(); adapter = nil
        payload = nil; deadline = nil; nextRotation = nil; startupDeadline = nil
        publishing = false; awaitingAdvertising = false; remainingSeconds = 0
        state = .idle; recovery = .none; self.message = message
    }

    private func fail(_ state: DiscoveryState = .failed, _ message: String, recovery: DiscoveryRecovery = .retry) {
        stop(); self.state = state; self.message = message; self.recovery = recovery
    }

    private func receive(_ event: PeripheralEvent) {
        switch event {
        case .permissionPending:
            state = .permissionNeeded; message = "Allow Bluetooth access to make this Mac discoverable."
            startupDeadline = nil
        case .initializing:
            if startupDeadline == nil { startupDeadline = now() + 10 }
        case .available:
            guard !publishing, deadline == nil else { return }
            if startupDeadline == nil { startupDeadline = now() + 10 }
            do { payload = try BlePayloadCodec.encode(nonce: random()) }
            catch { fail(.failed, "Could not generate a discovery nonce. Try again."); return }
            state = .discovering; message = "Starting Bluetooth discovery…"
            publishing = true; adapter?.publish()
        case .published:
            guard publishing, !awaitingAdvertising else { return }
            awaitingAdvertising = true; adapter?.advertise()
        case .advertising:
            guard awaitingAdvertising, deadline == nil else { return }
            startupDeadline = nil; deadline = now() + 120; nextRotation = now() + 30
            remainingSeconds = 120; state = .discovering; message = "This Mac is discoverable as aniCe."
        case .off: fail(.bluetoothOff, "Turn on Bluetooth in System Settings, then try again.", recovery: .bluetoothSettings)
        case .denied: fail(.permissionNeeded, "Allow aniCe in System Settings → Privacy & Security → Bluetooth, then try again.", recovery: .permissionSettings)
        case .unsupported: fail(.failed, "Bluetooth discovery is unavailable on this Mac.", recovery: .unsupported)
        case .resetting: fail(.failed, "Bluetooth was interrupted. Try again when it is available.")
        case .failure: fail(.failed, "Bluetooth discovery could not start. Try again.")
        }
    }

    func tick() {
        guard active else { return }
        let instant = now()
        if let startupDeadline, instant >= startupDeadline {
            fail(.failed, "Bluetooth discovery took too long to start. Try again."); return
        }
        guard let deadline else { return }
        if instant >= deadline { stop(message: "Discovery ended. Start again to make this Mac discoverable."); return }
        remainingSeconds = Int(ceil(deadline - instant))
        if let rotation = nextRotation, instant >= rotation {
            do { payload = try BlePayloadCodec.encode(nonce: random()) }
            catch { fail(.failed, "Could not refresh discovery. Try again."); return }
            nextRotation = rotation + (floor((instant - rotation) / 30) + 1) * 30
        }
    }

    func read(matches: Bool, offset: Int) -> DiscoveryRead {
        tick()
        guard active, deadline != nil, let payload else { return .unavailable }
        guard matches else { return .unknownCharacteristic }
        guard offset >= 0, offset <= payload.count else { return .invalidOffset }
        return .value(Data(payload.dropFirst(offset)))
    }
}
