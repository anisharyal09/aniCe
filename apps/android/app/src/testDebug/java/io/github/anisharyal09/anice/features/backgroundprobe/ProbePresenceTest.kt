// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.backgroundprobe

import org.junit.Assert.*
import org.junit.Test

class ProbePresenceTest {
  @Test fun duplicateEventsAndAdvertisingLossDoNotRetireConnectedOwnership() {
    val presence = ProbePresence()
    assertTrue(presence.event(1, true))
    assertFalse(presence.event(1, true))
    assertFalse(presence.event(2, true))
    assertFalse(presence.event(1, false))
    assertTrue(presence.present)
    assertTrue(presence.event(2, false))
    assertFalse(presence.present)
    assertFalse(presence.event(2, false))
    assertTrue(presence.event(1, true))
    presence.clear()
    assertFalse(presence.present)
    assertTrue(presence.event(1, true))
    presence.retire()
    assertFalse(presence.event(1, true))
    assertFalse(presence.event(2, true))
    assertFalse(presence.present)
    try { presence.event(3, true); fail("Unsupported source accepted") }
    catch (_: IllegalArgumentException) {}
  }
}
