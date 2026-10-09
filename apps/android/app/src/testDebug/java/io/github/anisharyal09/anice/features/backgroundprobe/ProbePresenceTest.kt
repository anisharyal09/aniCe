// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies companion binding, stale callbacks and combined radio presence boundaries.
package io.github.anisharyal09.anice.features.backgroundprobe

import org.junit.Assert.*
import org.junit.Test

class ProbePresenceTest {
  @Test fun restoredBindingWaitsForMissingFactsAndUnbindRetiresUnknownPresence() {
    val presence = ProbePresence()
    presence.bind()
    assertTrue(presence.present)
    assertTrue(presence.event(2, false)) // BLE may still be nearby without its cached callback.
    assertFalse(presence.event(1, false))
    assertTrue(presence.event(1, true))
    presence.clear()
    assertFalse(presence.present)
    presence.bind()
    assertTrue(presence.event(1, false)) // Rebinding can omit Bluetooth's cached fact instead.
    presence.retire()
    presence.bind()
    assertFalse(presence.present)
    assertFalse(presence.event(2, true))
  }
  @Test fun duplicateEventsAndAdvertisingLossDoNotRetireConnectedOwnership() {
    val presence = ProbePresence()
    presence.bind()
    assertTrue(presence.event(1, true))
    assertTrue(presence.event(1, true)) // Resuming observation may repeat a cached presence event.
    assertTrue(presence.event(2, true))
    assertTrue(presence.event(1, false))
    assertTrue(presence.present)
    assertFalse(presence.event(2, false))
    assertFalse(presence.present)
    assertFalse(presence.event(2, false))
    assertTrue(presence.event(1, true))
    presence.clear()
    assertFalse(presence.present)
    assertFalse(presence.event(1, true)) // A queued callback cannot restore an unbound service.
    presence.bind()
    assertTrue(presence.present) // Rebind restores unknown facts without requiring a replay.
    assertTrue(presence.event(1, true))
    presence.retire()
    assertFalse(presence.event(1, true))
    assertFalse(presence.event(2, true))
    assertFalse(presence.present)
    try { presence.event(3, true); fail("Unsupported source accepted") }
    catch (_: IllegalArgumentException) {}
  }
}
