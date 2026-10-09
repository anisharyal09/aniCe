// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.backgroundprobe

/** Advertising can disappear during a live GATT connection; retain ownership while either source exists. */
internal class ProbePresence {
  private val sources = mutableSetOf<Int>()
  private var retired = false
  val present get() = !retired && sources.isNotEmpty()
  fun event(source: Int, appeared: Boolean): Boolean {
    require(source == 1 || source == 2)
    if (retired) return false
    // A set coalesces repeated callbacks; notify only when aggregate presence actually changes.
    val previous = present
    if (appeared) sources.add(source) else sources.remove(source)
    return previous != present
  }
  fun clear() { sources.clear() }
  fun retire() { retired = true; sources.clear() }
}
