// SPDX-License-Identifier: GPL-3.0-or-later
// Combines companion advertisement, Bluetooth and binding facts into one presence decision.
package io.github.anisharyal09.anice.features.backgroundprobe

/** Advertising can disappear during a live GATT connection; retain ownership while either source exists. */
internal class ProbePresence {
  private val sources = mutableMapOf<Int, Boolean>()
  var bound = false
    private set
  private var retired = false
  // A restored system binding may omit either cached fact; unknown is not an absence event.
  val present get() = !retired && (sources.values.any { it } || (bound && sources.size < 2))
  fun bind() { if (!retired) { bound = true; sources.clear() } }
  fun event(source: Int, appeared: Boolean): Boolean {
    require(source == 1 || source == 2)
    if (retired || !bound) return false
    // Return current presence even for duplicates: policy may have paused/resumed since the last event.
    sources[source] = appeared
    return present
  }
  fun clear() { bound = false; sources.clear() }
  fun retire() { retired = true; clear() }
}
