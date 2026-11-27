// SPDX-License-Identifier: GPL-3.0-or-later
// Checks local timing attribution and bounded diagnostic export without native playback or peer identifiers.
import Foundation
import XCTest
@testable import aniCe

@MainActor final class MacPhoneAudioDiagnosticsTests: XCTestCase {
  func testRuntimeGateRequiresDebugExactPreviewAndExplicitOptIn() {
    let preview = "io.github.anisharyal09.anice.preview.transfer"
    XCTAssertTrue(MacPhoneAudioDiagnostics.allowed(debuggable: true, bundleIdentifier: preview, requested: true))
    XCTAssertFalse(MacPhoneAudioDiagnostics.allowed(debuggable: false, bundleIdentifier: preview, requested: true))
    XCTAssertFalse(MacPhoneAudioDiagnostics.allowed(debuggable: true, bundleIdentifier: preview, requested: false))
    XCTAssertFalse(MacPhoneAudioDiagnostics.allowed(debuggable: true,
      bundleIdentifier: "io.github.anisharyal09.anice", requested: true))
  }

  func testArrivalBurstAndReceiverWorkAreNotConfusedWithOutputLatency() throws {
    var time: Int64 = 0
    let probe = MacPhoneAudioDiagnostics(run: 1, nanoTime: { time })
    let first = probe.arrived(sequence: 1)
    time = 2_000_000
    probe.admitted(start: first, accepted: true)
    time = 100_000_000
    let second = probe.arrived(sequence: 4)
    time = 101_000_000
    probe.admitted(start: second, accepted: true)
    let third = probe.arrived(sequence: 5)
    time = 102_000_000
    probe.admitted(start: third, accepted: false)
    probe.observedOutput(PhoneAudioOutputDiagnostics(queuedFrames: 1920, resyncs: 2, unavailableDrops: 0))
    let fields = try XCTUnwrap(probe.report(state: 2, maintenance: false)).fields
    XCTAssertEqual(fields["arrival_interval_max_us"] as? Int64, 100_000)
    XCTAssertEqual(fields["arrival_interval_over_40ms"] as? Int64, 1)
    XCTAssertEqual(fields["arrival_interval_under_5ms"] as? Int64, 1)
    XCTAssertEqual(fields["receiver_admission_max_us"] as? Int64, 2000)
    XCTAssertEqual(fields["sequence_missing_packets"] as? Int64, 2)
    XCTAssertEqual(fields["accepted_packets"] as? Int64, 2)
    XCTAssertEqual(fields["discarded_packets"] as? Int64, 1)
    XCTAssertEqual(fields["output_resyncs"] as? Int, 2)
    XCTAssertTrue(fields["output_empty_pending_transitions"] is NSNull)
    XCTAssertFalse(fields.keys.contains(where: { $0.contains("peer") || $0.contains("pcm") || $0.contains("latency") }))
    XCTAssertTrue(JSONSerialization.isValidJSONObject(fields))
  }

  func testMaintenanceResetsArrivalBaselineWithoutResettingCounts() throws {
    var time: Int64 = 0
    let probe = MacPhoneAudioDiagnostics(run: 1, nanoTime: { time })
    _ = probe.arrived(sequence: 1)
    probe.resetArrivalBaseline()
    time = 40_000_000_000
    _ = probe.arrived(sequence: 2001)
    let fields = try XCTUnwrap(probe.report(state: 2, maintenance: false)).fields
    XCTAssertTrue(fields["arrival_interval_max_us"] is NSNull)
    XCTAssertEqual(fields["sequence_gap_events"] as? Int64, 0)
    XCTAssertEqual(fields["arriving_packets"] as? Int64, 2)
    XCTAssertTrue(fields["output_resyncs"] is NSNull)
  }

  func testReportBudgetAndFinalEmissionAreBounded() throws {
    var time: Int64 = 0
    let probe = MacPhoneAudioDiagnostics(run: 1, nanoTime: { time })
    for index in 0..<600 {
      time = Int64(index) * 1_000_000_000
      XCTAssertNotNil(probe.report(state: 2, maintenance: false))
      XCTAssertNil(probe.report(state: 2, maintenance: false))
    }
    time = 600_000_000_000
    XCTAssertNil(probe.report(state: 2, maintenance: false))
    XCTAssertFalse(probe.enabled)
    XCTAssertNil(probe.arrived(sequence: 2))
    XCTAssertNotNil(probe.report(state: 0, maintenance: false, terminal: true))
    XCTAssertNil(probe.report(state: 0, maintenance: false, terminal: true))
  }
}
