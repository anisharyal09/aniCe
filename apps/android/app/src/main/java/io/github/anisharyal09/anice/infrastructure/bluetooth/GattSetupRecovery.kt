// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds service-cache rediscovery during native GATT setup without retrying authentication failures.
package io.github.anisharyal09.anice.infrastructure.bluetooth

/** Coalesce service changes while an ATT setup operation is pending; never retry authentication. */
internal class GattSetupRecovery {
  private var invalidated = false
  private var rediscoveries = 0
  private var retriedMissingLayout = false

  fun retryMissingLayout(): Boolean {
    if (retriedMissingLayout) return false
    retriedMissingLayout = true
    return true
  }

  // ATT Invalid Handle means a cached descriptor no longer belongs to the current service table.
  fun retryInvalidHandle(status: Int): Boolean = status == 0x01 && retryMissingLayout()

  fun invalidate() {
    invalidated = true
  }

  fun afterPendingOperation(): Boolean {
    if (!invalidated) return false
    check(rediscoveries < 2)
    invalidated = false
    rediscoveries++
    return true
  }
}

enum class PairingTransportRecovery {
  retry,
  bluetoothSettings,
}

data class PairingTransportFailure(
    val message: String,
    val recovery: PairingTransportRecovery = PairingTransportRecovery.retry,
)
