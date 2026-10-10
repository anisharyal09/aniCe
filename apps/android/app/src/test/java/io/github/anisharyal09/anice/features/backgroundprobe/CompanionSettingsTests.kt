// SPDX-License-Identifier: GPL-3.0-or-later
// Tests device/fingerprint scoping of saved automatic connection settings.
package io.github.anisharyal09.anice.features.backgroundprobe

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import org.junit.Assert.*
import org.junit.Test

class CompanionSettingsTests {
  @Test fun automaticSetupRequiresTrustedSelectionAndAvailableIdlePresentation() {
    val peer = DeviceIdentity("mac", "Mac", "macos", "key", "fingerprint")
    var ready = 0
    var blocked = 0
    for (selected in listOf(null, peer)) for (available in listOf(false, true)) for (busy in listOf(false, true)) {
      val result = automaticSetupReady(selected, available, busy)
      assertEquals(selected != null && available && !busy, result)
      if (result) ready++ else blocked++
    }
    assertEquals(1, ready); assertEquals(7, blocked)
  }
  @Test fun settingsBelongToTheDisplayedRelationship() {
    val a = DeviceIdentity("00000000-0000-4000-8000-000000000001", "Mac A", "macos", "", "11".repeat(32))
    val b = a.copy(deviceId = "00000000-0000-4000-8000-000000000002", deviceName = "Mac B")
    val matching = listOf(a, a.copy(deviceName = "Renamed Mac"))
    val unrelated = listOf(null, b, a.copy(fingerprint = "22".repeat(32)))
    assertEquals(2, matching.size); assertEquals(3, unrelated.size)
    matching.forEach { assertTrue(hasConnectionSetup(it, a.deviceId, a.fingerprint)) }
    unrelated.forEach { assertFalse(hasConnectionSetup(it, a.deviceId, a.fingerprint)) }
    assertFalse(hasConnectionSetup(a, null, a.fingerprint))
    assertFalse(hasConnectionSetup(a, a.deviceId, null))
    assertFalse(hasConnectionSetup(a, null, null))
  }
}
