// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds anonymous pairing admission globally; new locators or explicit retries cannot reset the budget.
import Foundation

struct NearbyPairingAdmission {
  private var admissions: [TimeInterval] = []
  private var lastAdmission: TimeInterval?
  private var suppressedUntil: TimeInterval?

  mutating func admit(at now: TimeInterval) -> Bool {
    admissions.removeAll { now - $0 >= 120 }
    guard suppressedUntil.map({ now >= $0 }) ?? true,
      lastAdmission.map({ now - $0 >= 10 }) ?? true, admissions.count < 5
    else { return false }
    admissions.append(now)
    lastAdmission = now
    return true
  }

  mutating func dismiss(at now: TimeInterval) { suppressedUntil = now + 60 }
}
