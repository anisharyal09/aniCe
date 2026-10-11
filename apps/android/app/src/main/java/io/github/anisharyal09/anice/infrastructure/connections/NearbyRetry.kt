// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds retry delays and temporary candidate exclusions without treating addresses as trust.
package io.github.anisharyal09.anice.infrastructure.connections

/** Attempt-only backoff; addresses never confer trust or survive process restart. */
internal class NearbyRetry {
  private var failures = 0
  private val excluded = linkedMapOf<String, Long>()
  fun reset() { failures = 0; excluded.clear() }
  fun next(jitter: Double): Long {
    require(jitter in -0.1..0.1)
    val seconds = longArrayOf(2, 5, 15, 30, 60, 90)[failures.coerceAtMost(5)]
    if (failures < 5) failures++
    return (seconds * 1000 * (1 + jitter)).toLong().coerceAtMost(90_000L)
  }
  fun reject(address: String, now: Long) {
    exclusions(now)
    excluded.remove(address)
    if (excluded.size == 32) excluded.remove(excluded.keys.first())
    excluded[address] = now + 60_000
  }
  fun exclusions(now: Long): Set<String> {
    excluded.entries.removeAll { now >= it.value }
    return excluded.keys.toSet()
  }
}
