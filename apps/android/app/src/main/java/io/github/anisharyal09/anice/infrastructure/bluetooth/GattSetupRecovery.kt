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

  // A stale CCCD handle can alias a read-only attribute (0x03) or another service (0xF5).
  // Share the single layout refresh budget; this runs only before authentication.
  fun retrySubscriptionLayout(status: Int): Boolean =
    (status == 0x01 || status == 0x03 || status == 0xF5) && retryMissingLayout()

  // A successful read with the wrong payload also identifies a stale handle alias.
  fun retryProfileRead(status: Int): Boolean =
    (status == 0 || status == 1 || status == 2 || status == 10) && retryMissingLayout()

  fun subscriptionFailure(status: Int): PairingTransportFailure? =
    if (status == 0) null else PairingTransportFailure(
      "Could not subscribe to the Mac's Bluetooth reply channel (GATT status $status)."
    )

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
