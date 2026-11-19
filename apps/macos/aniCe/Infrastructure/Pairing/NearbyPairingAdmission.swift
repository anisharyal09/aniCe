// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds anonymous pairing admission globally; new locators or explicit retries cannot reset the budget.
import Foundation

struct NearbyPairingAdmission {
  private var admissions: [TimeInterval] = []
  private var lastAdmission: TimeInterval?
  private var suppressedUntil: TimeInterval?

  func nextAdmission(at now: TimeInterval) -> TimeInterval {
    let recent = admissions.filter { now - $0 < 120 }
    return max(now, suppressedUntil ?? now, (lastAdmission.map { $0 + 10 } ?? now),
      recent.count >= 5 ? (recent.first! + 120) : now)
  }

  mutating func admit(at now: TimeInterval) -> Bool {
    admissions.removeAll { now - $0 >= 120 }
    guard nextAdmission(at: now) <= now else { return false }
    admissions.append(now)
    lastAdmission = now
    return true
  }

  mutating func dismiss(at now: TimeInterval) { suppressedUntil = now + 60 }
}
