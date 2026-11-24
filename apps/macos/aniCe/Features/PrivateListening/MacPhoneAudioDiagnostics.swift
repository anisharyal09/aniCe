// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps bounded, opt-in local arrival/admission evidence without retaining audio or peer identifiers.
import Foundation

struct MacPhoneAudioDiagnosticReport {
  let fields: [String: Any]
}

@MainActor final class MacPhoneAudioDiagnostics {
  private struct Timing {
    var samples: Int64 = 0
    var maximum: Int64?
    var windowMaximum: Int64?
    var over40ms: Int64 = 0
    var under5ms: Int64 = 0
    mutating func record(_ duration: Int64) {
      guard duration >= 0 else { return }
      samples += 1
      maximum = max(maximum ?? 0, duration)
      windowMaximum = max(windowMaximum ?? 0, duration)
      if duration > 40_000_000 { over40ms += 1 }
      if duration < 5_000_000 { under5ms += 1 }
    }
    mutating func fields(_ prefix: String) -> [String: Any] {
      let result: [String: Any] = [
        "\(prefix)_samples": samples, "\(prefix)_max_us": maximum.map { $0 / 1000 } as Any? ?? NSNull(),
        "\(prefix)_window_max_us": windowMaximum.map { $0 / 1000 } as Any? ?? NSNull(),
        "\(prefix)_over_40ms": over40ms, "\(prefix)_under_5ms": under5ms]
      windowMaximum = nil
      return result
    }
  }

  static let prefix = "phone_audio_diag "
  private let run: Int64
  private let nanoTime: () -> Int64
  private let startedAt: Int64
  private var lastReportAt: Int64?
  private var lastWindowStartedAt: Int64 = 0
  private var reports = 0
  private var finalReported = false
  private(set) var enabled = true
  private var arrival = Timing()
  private var admission = Timing()
  private var previousArrivalAt: Int64?
  private var previousSequence: Int64?
  private var arrivingPackets: Int64 = 0
  private var acceptedPackets: Int64 = 0
  private var discardedPackets: Int64 = 0
  private var gapEvents: Int64 = 0
  private var missingPackets: Int64 = 0
  private var output: PhoneAudioOutputDiagnostics?
  private var outputObservedAt: Int64?

  init(run: Int64, nanoTime: @escaping () -> Int64) {
    self.run = run
    self.nanoTime = nanoTime
    startedAt = nanoTime()
  }

  static func allowed(debuggable: Bool, bundleIdentifier: String, requested: Bool) -> Bool {
    debuggable && bundleIdentifier == "io.github.anisharyal09.anice.preview.transfer" && requested
  }

  static var runtimeEnabled: Bool {
    #if DEBUG
    allowed(debuggable: true, bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
      requested: ProcessInfo.processInfo.environment["ANICE_PHONE_AUDIO_DIAGNOSTICS"] == "1")
    #else
    false
    #endif
  }

  func timestamp() -> Int64? { enabled ? nanoTime() : nil }

  func arrived(sequence: Int64) -> Int64? {
    guard enabled else { return nil }
    let time = nanoTime()
    if let previousArrivalAt { arrival.record(time - previousArrivalAt) }
    previousArrivalAt = time
    if let previousSequence, sequence > previousSequence, sequence - previousSequence > 1 {
      gapEvents += 1
      missingPackets += sequence - previousSequence - 1
    }
    self.previousSequence = max(previousSequence ?? 0, sequence)
    arrivingPackets += 1
    return time
  }

  func admitted(start: Int64?, accepted: Bool) {
    guard enabled, let start else { return }
    admission.record(nanoTime() - start)
    if accepted { acceptedPackets += 1 } else { discardedPackets += 1 }
  }

  /// Maintenance is an intentional interruption, not evidence of ordinary delivery loss.
  func resetArrivalBaseline() { previousArrivalAt = nil; previousSequence = nil }

  func observedOutput(_ value: PhoneAudioOutputDiagnostics) {
    guard enabled else { return }
    output = value
    outputObservedAt = nanoTime()
  }

  func report(state: Int64, maintenance: Bool, terminal: Bool = false) -> MacPhoneAudioDiagnosticReport? {
    guard !finalReported else { return nil }
    let time = nanoTime()
    let elapsed = max(0, time - startedAt)
    if !terminal && (reports >= 600 || elapsed > 600_000_000_000) {
      enabled = false
      return nil
    }
    if !terminal, let lastReportAt, time - lastReportAt < 1_000_000_000 { return nil }
    let windowStarted = lastWindowStartedAt
    lastWindowStartedAt = elapsed
    if terminal { finalReported = true; enabled = false } else { reports += 1 }
    lastReportAt = time
    var fields: [String: Any] = [
      "version": 1, "side": "macos", "run": run, "elapsed_ms": elapsed / 1_000_000,
      "window_start_elapsed_ms": windowStarted / 1_000_000,
      "terminal": terminal, "state": state, "maintenance": maintenance,
      "arriving_packets": arrivingPackets, "accepted_packets": acceptedPackets,
      "discarded_packets": discardedPackets, "sequence_gap_events": gapEvents,
      "sequence_missing_packets": missingPackets,
      "output_queued_frames": output?.queuedFrames as Any? ?? NSNull(),
      "output_resyncs": output?.resyncs as Any? ?? NSNull(),
      "output_unavailable_drops": output?.unavailableDrops as Any? ?? NSNull(),
      "output_scheduled_packets": output?.scheduledPackets as Any? ?? NSNull(),
      "output_played_back_callbacks": output?.playedBackCallbacks as Any? ?? NSNull(),
      "output_empty_pending_transitions": output?.emptyPendingTransitions as Any? ?? NSNull(),
      "output_completion_max_us": output?.completionMaximumMicros as Any? ?? NSNull(),
      "output_snapshot_age_us": outputObservedAt.map { max(0, time - $0) / 1000 } as Any? ?? NSNull()
    ]
    fields.merge(arrival.fields("arrival_interval")) { _, new in new }
    fields.merge(admission.fields("receiver_admission")) { _, new in new }
    return MacPhoneAudioDiagnosticReport(fields: fields)
  }
}
