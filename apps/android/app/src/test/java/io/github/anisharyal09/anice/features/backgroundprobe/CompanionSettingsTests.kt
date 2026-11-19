// SPDX-License-Identifier: GPL-3.0-or-later
// Tests device/fingerprint scoping of saved automatic connection settings.
package io.github.anisharyal09.anice.features.backgroundprobe

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import org.junit.Assert.*
import org.junit.Test

class CompanionSettingsTests {
  @Test fun approvalLaunchIsOneShotAndRetiredGenerationsCannotReclaimIt() {
    val gate = CompanionApprovalGate()
    assertFalse(gate.owns(1))
    assertTrue(gate.claim(1))
    repeat(10) { assertFalse(gate.claim(1)) }
    assertTrue(gate.owns(1))
    assertTrue(gate.claim(3))
    assertFalse(gate.claim(1))
    assertFalse(gate.claim(2))
    assertFalse(gate.owns(1))
    assertTrue(gate.owns(3))
    assertTrue(gate.claim(4))
  }
  @Test fun pendingPhasesBlockAnotherEnrollmentWithoutDisablingSavedSettings() {
    val idle = setOf(CompanionSetupPhase.READY, CompanionSetupPhase.FAILED)
    for (phase in CompanionSetupPhase.entries) {
      assertEquals(phase !in idle, phase.busy)
    }
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
