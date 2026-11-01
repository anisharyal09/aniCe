// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Defines recording-bound playback commands and framed line serialization for the adapter pipe.

import Foundation

/// The adapter's recording revision travels with the user's action. A process
/// alone is not enough: it may start another recording before the pipe is read.
struct PlaybackContext: Equatable {
    let pid: Int32
    let revision: UUID

    init(pid: Int32, revision: UUID) { self.pid = pid; self.revision = revision }

    init?(reply: [String: Any]) {
        guard let rawPID = reply["pid"] as? NSNumber, CFGetTypeID(rawPID) != CFBooleanGetTypeID(),
              let pid = Int32(exactly: rawPID.doubleValue), pid > 0,
              let rawRevision = reply["playbackRevision"] as? String,
              let revision = UUID(uuidString: rawRevision) else { return nil }
        self.init(pid: pid, revision: revision)
    }
}

/// A bounded command shared by the UI process and its playback adapter.
enum PlaybackCommand: Equatable {
    case toggle, next, previous, sample, refresh
    case seek(Double)
    case validate(UUID, PlaybackContext)
    case source(PlaybackSource.Selection?)
    static let maximumMessageBytes = 2048

    init?(message: String) {
        guard message.utf8.count <= Self.maximumMessageBytes else { return nil }
        switch message {
        case "toggle": self = .toggle
        case "next": self = .next
        case "previous": self = .previous
        case "sample": self = .sample
        case "refresh": self = .refresh
        case "source-auto": self = .source(nil)
        default:
            let parts = message.split(separator: " ", omittingEmptySubsequences: false)
            if parts.count == 3, parts[0] == "source", let pid = Int32(parts[1]),
               let data = Data(base64Encoded: String(parts[2])), let bundle = String(data: data, encoding: .utf8) {
                let selection = PlaybackSource.Selection(pid: pid, bundleIdentifier: bundle)
                guard selection.isValid else { return nil }
                self = .source(selection); return
            }
            if parts.count == 4, parts[0] == "validate", let id = UUID(uuidString: String(parts[1])),
               let pid = Int32(parts[2]), pid > 0, let revision = UUID(uuidString: String(parts[3])) {
                self = .validate(id, PlaybackContext(pid: pid, revision: revision)); return
            }
            guard message.hasPrefix("seek "),
                  let position = Double(message.dropFirst(5)), Self.validPosition(position) else { return nil }
            self = .seek(position)
        }
    }

    var requiresPlaybackContext: Bool {
        switch self {
        case .toggle, .next, .previous, .seek, .sample: return true
        case .validate, .source, .refresh: return false
        }
    }

    var message: String? {
        switch self {
        case .toggle: return "toggle"
        case .next: return "next"
        case .previous: return "previous"
        case .sample: return "sample"
        case .refresh: return "refresh"
        case .source(nil): return "source-auto"
        case .source(let selection?):
            guard selection.isValid else { return nil }
            return "source \(selection.pid) \(Data(selection.bundleIdentifier.utf8).base64EncodedString())"
        case .validate(let id, let context):
            guard context.pid > 0 else { return nil }
            return "validate \(id.uuidString) \(context.pid) \(context.revision.uuidString)"
        case .seek(let position): return Self.validPosition(position) ? "seek \(position)" : nil
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains("\0")
    }

    private static func validPosition(_ value: Double) -> Bool {
        value.isFinite && (0...604_800).contains(value)
    }
}

/// Basic controls require the recording revision; bare commands never reach the native player.
struct PlaybackRequest: Equatable {
    let command: PlaybackCommand
    let context: PlaybackContext?
    var requestID: UUID?

    init(command: PlaybackCommand, context: PlaybackContext? = nil) {
        self.requestID = nil
        self.command = command
        self.context = command.requiresPlaybackContext ? context : nil
    }

    init?(message: String) {
        guard message.utf8.count <= PlaybackCommand.maximumMessageBytes else { return nil }
        if message.hasPrefix("request ") {
            let parts=message.split(separator:" ",maxSplits:2,omittingEmptySubsequences:false)
            guard parts.count==3, let id=UUID(uuidString:String(parts[1])), var inner=PlaybackRequest(message:String(parts[2])), inner.requestID==nil else { return nil }
            inner.requestID=id; self=inner; return
        }
        if message.hasPrefix("play ") {
            let parts = message.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let pid = Int32(parts[1]), pid > 0,
                  let revision = UUID(uuidString: String(parts[2])),
                  let command = PlaybackCommand(message: String(parts[3])), command.requiresPlaybackContext else { return nil }
            self.init(command: command, context: PlaybackContext(pid: pid, revision: revision))
        } else {
            guard let command = PlaybackCommand(message: message), !command.requiresPlaybackContext else { return nil }
            self.init(command: command)
        }
    }

    var message: String? {
        guard let base = bareMessage else { return nil }
        let result=requestID.map { "request \($0.uuidString) \(base)" } ?? base
        return result.utf8.count<=PlaybackCommand.maximumMessageBytes ? result:nil
    }
    private var bareMessage: String? {
        guard let message = command.message else { return nil }
        guard command.requiresPlaybackContext else { return message }
        guard let context, context.pid > 0 else { return nil }
        return "play \(context.pid) \(context.revision.uuidString) \(message)"
    }
}

/// Pipe delivery can split one line or batch many. An oversized line is discarded
/// through its newline only; subsequent valid commands still run.
struct PlaybackCommandFramer {
    private var line = Data()
    private var discarding = false

    mutating func append(_ data: Data) -> [PlaybackRequest?] {
        var result: [PlaybackRequest?] = []
        for byte in data {
            if byte == 0x0A {
                let command = discarding ? nil : String(data: line, encoding: .utf8).flatMap(PlaybackRequest.init(message:))
                result.append(command)
                line.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if line.count >= PlaybackCommand.maximumMessageBytes {
                    line.removeAll(keepingCapacity: true)
                    discarding = true
                } else { line.append(byte) }
            }
        }
        return result
    }
}

/// Observational reads cannot delay controls; source selection stays serialized with scans.
struct PlaybackDispatch: Sendable {
    let observation = DispatchQueue(label: "io.github.anisharyal09.anice.now-playing-watch")
    private let samples = DispatchQueue(label: "io.github.anisharyal09.anice.now-playing-samples", qos: .userInitiated)
    private let commands = DispatchQueue(label: "io.github.anisharyal09.anice.now-playing-commands", qos: .userInitiated)

    func submit(_ command: PlaybackCommand, run: @escaping @Sendable () -> Void) {
        switch command {
        // A post-command sample may wait on MediaRemote; it must not queue ahead of the next tap.
        case .source, .refresh: observation.async(execute:run)
        case .sample: samples.async(execute:run)
        default: commands.async(execute:run)
        }
    }
}

/// Pairs one capability callback with its initial recording sample, regardless of callback order.
final class RecordingCapabilities: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var context: [String: Any]?
    private var values: [String: Any]?
    private var delivered = false
    private var completed = false
    private func take() -> [String: Any]? {
        guard !delivered, let context, let values else { return nil }
        delivered = true
        return context.merging(values) { _, new in new }
    }
    func arm(_ context: [String: Any]) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }; self.context = context; return take()
    }
    func expire() -> [String: Any]? {
        lock.lock();defer { lock.unlock() }
        guard values==nil else { return nil };values=["capabilityState":"unavailable"];return take()
    }
    func complete(_ values: [String: Any]) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return nil }
        completed=true;delivered=false;self.values=values
        ready.signal()
        return take()
    }
    func wait(until deadline: DispatchTime) -> Bool {
        ready.wait(timeout:deadline) == .success
    }
    var currentValues: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// Late command discovery updates support without overwriting a newer playback state.
struct NativePlaybackControls {
    private var toggle = false, play = false, pause = false
    private var playing: Bool?
    mutating func sample(_ info: [String: Any]) {
        if let state = info["isPlaying"] as? Bool { playing = state }
        else if let rate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue, rate.isFinite { playing = rate > 0 }
    }
    mutating func capabilities(_ info: [String: Any]) {
        if info["capabilityState"] as? String == "unsupported" { toggle=false;play=false;pause=false;return }
        if let value=info["canToggle"] as? Bool { toggle=value }
        if let value=info["canPlay"] as? Bool { play=value }
        if let value=info["canPause"] as? Bool { pause=value }
    }
    var command: Int32 {
        if toggle { return 2 }
        if playing == true && pause { return 1 }
        if playing == false && play { return 0 }
        return 2
    }
}
