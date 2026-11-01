// SPDX-License-Identifier: GPL-3.0-or-later
// Measures the current transfer rate over a bounded observation window.
import Foundation

/// Reports the rate across the most recent `samples` observations rather than across the whole
/// transfer.
///
/// A lifetime average (`total / elapsed`) cannot answer "how fast is it going now": it hides a ramp
/// up, keeps reporting a healthy number while the link has stalled, and drags a genuinely fast
/// second file down behind a slow first one. A bounded window decays toward zero when the link stops
/// delivering and reflects the current link again as soon as bytes resume.
struct TransferRate {
  private let samples: Int
  private var counts: [Int64]
  private var times: [TimeInterval]
  private var size = 0
  private var next = 0

  // Twenty intervals at the 250-ms publication cadence span five seconds, including bursty LAN ACKs.
  init(samples: Int = 21) {
    precondition(samples >= 2, "A rate needs two observations.")
    self.samples = samples
    counts = Array(repeating: 0, count: samples)
    times = Array(repeating: 0, count: samples)
  }

  /// Records `totalBytes` observed at `at` and returns the rate in bytes per second.
  /// Returns `0` until two observations exist and whenever the window covers no progress, which
  /// callers present as "no rate available" rather than as a measured zero.
  mutating func add(_ totalBytes: Int64, at: TimeInterval) -> Double {
    counts[next] = totalBytes
    times[next] = at
    next = (next + 1) % samples
    if size < samples { size += 1 }
    guard size >= 2 else { return 0 }
    let oldest = size < samples ? 0 : next
    let newest = (next - 1 + samples) % samples
    let span = times[newest] - times[oldest]
    let delta = counts[newest] - counts[oldest]
    guard span > 0, delta > 0 else { return 0 }
    return Double(delta) / span
  }
}
