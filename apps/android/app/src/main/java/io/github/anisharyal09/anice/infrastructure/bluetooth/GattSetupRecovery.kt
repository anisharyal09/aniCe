// SPDX-License-Identifier: GPL-3.0-or-later
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
