// SPDX-License-Identifier: GPL-3.0-or-later
// Qualifies LAN throughput and bounds transfer sender credit.
import Foundation

// Reduced LAN chunks need immediate credit to keep the sender's smaller pipeline supplied.
func transferAckThreshold(maximumChunk: Int64, maximumWindow: Int64, chunkBytes: Int64) -> Int64 {
  if maximumChunk <= 3072 { return maximumChunk * min(8, max(1, maximumWindow / 2)) }
  let chunk = min(maximumChunk, chunkBytes)
  return chunk * (maximumChunk > 4096 && chunk < maximumChunk ? 1 : max(1, maximumWindow / 4))
}

// Bounds unacknowledged LAN bytes before allowing the negotiated high-throughput window.
struct TransferSendWindow {
  let maximumChunk: Int64
  let maximumWindow: Int64
  let lan: Bool
  private var probing: Bool
  private var probeSubmitted = false
  private var constrained = false
  private var lastAcknowledgedAt: TimeInterval
  private var probeStartedAt: TimeInterval
  private var reprobe = false
  private var drainRequested = false
  private var draining = false
  private var decision: Bool?
  private var timelySince: TimeInterval?
  init(maximumChunk: Int64, maximumWindow: Int64, lan: Bool, started: TimeInterval) {
    self.maximumChunk = maximumChunk; self.maximumWindow = maximumWindow; self.lan = lan
    probing = lan && maximumChunk > 4096
    lastAcknowledgedAt = started
    probeStartedAt = started
  }
  // Sustained fallback amortizes live per-record validation under a 128-KiB fallback backlog cap.
  var chunkBytes: Int64 {
    if probing { return min(4096, maximumChunk) }
    return constrained ? min(65536, maximumChunk) : maximumChunk
  }
  var creditBytes: Int64 { chunkBytes * (probing || draining ? 1 : constrained ? min(2, maximumWindow) : maximumWindow) }
  // Source IO and encoding precede submission and cannot measure the path's acknowledgement delay.
  mutating func beginSubmission(_ now: TimeInterval, windowEmpty: Bool = false) {
    if probing && !probeSubmitted {
      lastAcknowledgedAt = now
      probeStartedAt = now
      probeSubmitted = true
    } else if !probing && windowEmpty {
      if ((now - lastAcknowledgedAt) * 1_000_000_000).rounded() > 100_000_000 { timelySince = nil }
      lastAcknowledgedAt = now
    }
  }
  // Only advancing, correlated ACKs reach this method; duplicates cannot qualify a fast path.
  mutating func acknowledged(_ now: TimeInterval, fullyConfirmed: Bool) {
    if probing && !fullyConfirmed { return }
    let elapsed = now - lastAcknowledgedAt
    // Compare at nanosecond precision rather than floating-point subtraction noise at 100 ms.
    let timely = (elapsed * 1_000_000_000).rounded() <= 100_000_000
    if probing { if decision == nil { decision = !timely } }
    else if constrained {
      if !timely { timelySince = nil } else if timelySince == nil { timelySince = lastAcknowledgedAt }
      // Batched ACK arrivals cannot qualify recovery without a full second of steady progress.
      let stable = timelySince.map { ((now - $0) * 1_000_000_000).rounded() >= 1_000_000_000 } ?? false
      if draining && fullyConfirmed || stable && now - probeStartedAt >= 5 {
        if fullyConfirmed { reprobe = true } else { drainRequested = true }
      }
    }
    else if lan && maximumChunk > 4096 && elapsed > 1 { decision = true }
    lastAcknowledgedAt = now
  }
  // Apply shrinkage between records, never while a previously admitted source read is suspended.
  mutating func advance() {
    if let decision { constrained = decision; probing = false; timelySince = nil }
    decision = nil
    // A one-chunk budget drains a continuously replenished two-chunk pipeline before probing.
    if drainRequested { draining = true; drainRequested = false }
    if reprobe { probing = true; probeSubmitted = false; draining = false; probeStartedAt = lastAcknowledgedAt; reprobe = false }
  }
}
