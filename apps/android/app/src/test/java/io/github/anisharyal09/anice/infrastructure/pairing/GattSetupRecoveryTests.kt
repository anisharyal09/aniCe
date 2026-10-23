// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises bounded native service-cache recovery and rejection of unrelated ATT failures.
package io.github.anisharyal09.anice.infrastructure.pairing

import io.github.anisharyal09.anice.infrastructure.bluetooth.GattSetupRecovery
import org.junit.Assert.*
import org.junit.Test

class GattSetupRecoveryTests {
  @Test fun subscriptionFailuresPreserveNativeStatus() {
    val recovery = GattSetupRecovery()
    assertNull(recovery.subscriptionFailure(0))
    for (status in listOf(245, 133, 257)) {
      assertEquals("Could not subscribe to the Mac's Bluetooth reply channel (GATT status $status).",
        recovery.subscriptionFailure(status)!!.message)
    }
    assertTrue(recovery.retrySubscriptionLayout(1))
    assertFalse(recovery.retrySubscriptionLayout(1))
    assertTrue(recovery.subscriptionFailure(1)!!.message.contains("GATT status 1"))
  }
  @Test fun staleHandleAliasingAnotherServiceSharesOneRefreshBudget() {
    for (first in listOf(1, 245)) {
      val recovery = GattSetupRecovery()
      assertTrue(recovery.retrySubscriptionLayout(first))
      assertFalse(recovery.retrySubscriptionLayout(245))
      assertFalse(recovery.retrySubscriptionLayout(1))
      assertFalse(recovery.retryMissingLayout())
      assertTrue(recovery.subscriptionFailure(245)!!.message.contains("245"))
    }
    val missing = GattSetupRecovery()
    assertTrue(missing.retryMissingLayout())
    assertFalse(missing.retrySubscriptionLayout(245))
  }
  @Test fun invalidDescriptorHandleSharesTheSingleLayoutRetry() {
    val recovery = GattSetupRecovery()
    for (status in listOf(0, 2, 3, 5, 15, 133, 257)) assertFalse(recovery.retrySubscriptionLayout(status))
    assertTrue(recovery.retrySubscriptionLayout(1))
    assertFalse(recovery.retrySubscriptionLayout(1))
    assertFalse(recovery.retryMissingLayout())
    val missing = GattSetupRecovery()
    assertTrue(missing.retryMissingLayout())
    assertFalse(missing.retrySubscriptionLayout(1))
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
