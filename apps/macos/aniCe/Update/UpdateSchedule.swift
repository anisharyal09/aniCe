// SPDX-License-Identifier: GPL-3.0-or-later
// Computes the 19:30 Nepal release-check deadline and preserves overdue checks through retry backoff.
import Foundation

enum UpdateSchedule {
  static let day: TimeInterval = 86_400
  private static let nepalEveningUTC: TimeInterval = 49_500 // 19:30 UTC+05:45 is 13:45 UTC.

  static func latestEvening(_ now: Date) -> Date {
    Date(timeIntervalSince1970: floor((now.timeIntervalSince1970 - nepalEveningUTC) / day) * day + nepalEveningUTC)
  }

  static func retryDelay(_ failures: Int) -> TimeInterval {
    failures <= 0 ? 0 : min(900 * pow(2, Double(min(failures, 7) - 1)), day)
  }

  static func nextCheck(now: Date, lastSuccess: TimeInterval, lastAttempt: TimeInterval, failures: Int) -> Date {
    let time = now.timeIntervalSince1970
    let evening = latestEvening(now).timeIntervalSince1970
    let completed = lastSuccess >= evening && lastSuccess <= time
    let deadline = completed ? evening + day : evening
    let retry = lastAttempt > 0 && lastAttempt <= time && failures > 0 ? lastAttempt + retryDelay(failures) : 0
    let next = max(deadline, retry)
    // An epoch round trip can move an already-due instant fractionally into the future.
    return next > time ? Date(timeIntervalSince1970: next) : now
  }
}
