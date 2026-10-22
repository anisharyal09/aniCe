// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises bounded native service-cache recovery and rejection of unrelated ATT failures.
package io.github.anisharyal09.anice.infrastructure.pairing

import io.github.anisharyal09.anice.infrastructure.bluetooth.GattSetupRecovery
import org.junit.Assert.*
import org.junit.Test

class GattSetupRecoveryTests {
  @Test fun invalidDescriptorHandleSharesTheSingleLayoutRetry() {
    val recovery = GattSetupRecovery()
    for (status in listOf(0, 2, 3, 5, 15, 133, 257)) assertFalse(recovery.retryInvalidHandle(status))
    assertTrue(recovery.retryInvalidHandle(1))
    assertFalse(recovery.retryInvalidHandle(1))
    assertFalse(recovery.retryMissingLayout())
    val missing = GattSetupRecovery()
    assertTrue(missing.retryMissingLayout())
    assertFalse(missing.retryInvalidHandle(1))
  }
  @Test
  fun missingLayoutGetsOnePublicRediscoveryPerConnection() {
    val recovery = GattSetupRecovery()
    assertTrue(recovery.retryMissingLayout())
    assertFalse(recovery.retryMissingLayout())
    recovery.invalidate()
    assertTrue(recovery.afterPendingOperation())
    assertFalse(recovery.retryMissingLayout())
    assertTrue(GattSetupRecovery().retryMissingLayout())
  }

  @Test
  fun serviceChangesCoalesceAndRediscoverAfterThePendingOperation() {
    val recovery = GattSetupRecovery()
    assertFalse(recovery.afterPendingOperation())
    recovery.invalidate()
    recovery.invalidate()
    assertTrue(recovery.afterPendingOperation())
    assertFalse(recovery.afterPendingOperation())
    recovery.invalidate()
    assertTrue(recovery.afterPendingOperation())
    assertFalse(recovery.afterPendingOperation())
  }

  @Test
  fun repeatedInvalidationFailsClosedAndFreshConnectionStartsClean() {
    val recovery = GattSetupRecovery()
    repeat(2) {
      recovery.invalidate()
      assertTrue(recovery.afterPendingOperation())
    }
    recovery.invalidate()
    assertThrows(IllegalStateException::class.java) { recovery.afterPendingOperation() }
    assertFalse(GattSetupRecovery().afterPendingOperation())
  }
}
