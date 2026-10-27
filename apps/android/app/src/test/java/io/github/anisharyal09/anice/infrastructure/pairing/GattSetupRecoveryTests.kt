// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises bounded service-cache recovery and native GATT submission failure reporting.
package io.github.anisharyal09.anice.infrastructure.pairing

import io.github.anisharyal09.anice.infrastructure.bluetooth.GattSetupRecovery
import io.github.anisharyal09.anice.infrastructure.bluetooth.requireGattWriteSubmission
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class GattSetupRecoveryTests {
  @Test fun immediateWriteRejectionPreservesUnknownNativeStatusesAsIoFailures() {
    requireGattWriteSubmission(0)
    val statuses = listOf(-1, 1, 3, 133, 201, Int.MAX_VALUE)
    assertEquals(6, statuses.size)
    for (status in statuses) {
      val failure = assertThrows(IOException::class.java) { requireGattWriteSubmission(status) }
      assertEquals("Bluetooth write submission rejected (BluetoothStatusCodes $status).", failure.message)
      assertFalse(failure.message!!.contains("GATT status"))
    }
  }

  @Test fun legacyWriteRejectionDoesNotInventANativeStatus() {
    val failure = assertThrows(IOException::class.java) { requireGattWriteSubmission(null) }
    assertEquals("Bluetooth write submission rejected (legacy API returned false).", failure.message)
  }

  @Test fun profileReadMismatchSharesRefreshBudgetWithoutRetryingAuthenticationErrors() {
    for (status in listOf(0, 1, 2, 10)) {
      val recovery = GattSetupRecovery()
      assertTrue(recovery.retryProfileRead(status))
      assertFalse(recovery.retryProfileRead(status))
      assertFalse(recovery.retrySubscriptionLayout(3))
    }
    val recovery = GattSetupRecovery()
    for (status in listOf(5, 8, 15, 133, 257)) assertFalse(recovery.retryProfileRead(status))
    assertTrue(recovery.retrySubscriptionLayout(3))
    assertFalse(recovery.retryProfileRead(0))
  }

  @Test fun subscriptionFailuresPreserveNativeStatus() {
    val recovery = GattSetupRecovery()
    assertNull(recovery.subscriptionFailure(0))
    for (status in listOf(3, 245, 133, 257)) {
      assertEquals("Could not subscribe to the Mac's Bluetooth reply channel (GATT status $status).",
        recovery.subscriptionFailure(status)!!.message)
    }
    assertTrue(recovery.retrySubscriptionLayout(1))
    assertFalse(recovery.retrySubscriptionLayout(1))
    assertTrue(recovery.subscriptionFailure(1)!!.message.contains("GATT status 1"))
  }
  @Test fun staleHandleAliasingAnotherServiceSharesOneRefreshBudget() {
    for (first in listOf(1, 3, 245)) {
      val recovery = GattSetupRecovery()
      assertTrue(recovery.retrySubscriptionLayout(first))
      assertFalse(recovery.retrySubscriptionLayout(245))
      assertFalse(recovery.retrySubscriptionLayout(1))
      assertFalse(recovery.retrySubscriptionLayout(3))
      assertFalse(recovery.retryMissingLayout())
      assertTrue(recovery.subscriptionFailure(245)!!.message.contains("245"))
    }
    val missing = GattSetupRecovery()
    assertTrue(missing.retryMissingLayout())
    assertFalse(missing.retrySubscriptionLayout(245))
  }
  @Test fun invalidDescriptorHandleSharesTheSingleLayoutRetry() {
    val recovery = GattSetupRecovery()
    for (status in listOf(0, 2, 5, 8, 15, 133, 257)) assertFalse(recovery.retrySubscriptionLayout(status))
    assertTrue(recovery.retrySubscriptionLayout(1))
    assertFalse(recovery.retrySubscriptionLayout(1))
    assertFalse(recovery.retryMissingLayout())
    val missing = GattSetupRecovery()
    assertTrue(missing.retryMissingLayout())
    assertFalse(missing.retrySubscriptionLayout(1))
    assertFalse(missing.retrySubscriptionLayout(3))
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
