// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds service-cache rediscovery during native GATT setup without retrying authentication failures.
package io.github.anisharyal09.anice.infrastructure.bluetooth

/** Coalesce service changes while an ATT setup operation is pending; never retry authentication. */
internal class GattSetupRecovery {
  private var invalidated = false
  private var rediscoveries = 0
  private var retriedMissingLayout = false
  private var availabilityReads = 0

  /** Only a fresh trusted session may wait for pairing to release its unchanged public profile. */
  fun retrySessionAvailability(status: Int, comparisonAvailable: Boolean, trustedSession: Boolean): Boolean {
    if (!trustedSession || !(status == 14 || status == 0 && comparisonAvailable) || availabilityReads >= 12)
      return false
    availabilityReads++
    return true
  }

  fun retryMissingLayout(): Boolean {
    if (retriedMissingLayout) return false
    retriedMissingLayout = true
    return true
  }

  // A stale CCCD handle can alias a read-only attribute (0x03), CCCD configuration error (0xF2), or another service (0xF5).
  // Share the single layout refresh budget; this runs only before authentication.
  fun retrySubscriptionLayout(status: Int): Boolean =
    (status == 0x01 || status == 0x03 || status == 0xF2 || status == 0xF5) && retryMissingLayout()

  // A successful read with the wrong payload also identifies a stale handle alias.
  fun retryProfileRead(status: Int): Boolean =
    (status == 0 || status == 1 || status == 2 || status == 10) && retryMissingLayout()

  fun profileReadFailure(status: Int, trustedSession: Boolean = false): PairingTransportFailure = PairingTransportFailure(
    when (status) {
      14 -> if (trustedSession)
        "The Mac's Bluetooth service isn't ready (GATT status 14). Pairing is still saved. Keep aniCe open on the Mac and choose Connect again."
        else "The Mac's discovery service is not currently available (GATT status 14). Keep the Mac's nearby setup or a fresh manual invitation open, then retry."
      242 -> if (trustedSession)
        "The phone rejected the Mac's Bluetooth service lookup (GATT status 242). Pairing is still saved. Reopen aniCe on the Mac and choose Connect again."
        else "The Mac's discovery read was rejected after Bluetooth service lookup (GATT status 242). Stop and restart nearby setup on the Mac, then find it again."
      else -> "Could not verify the Mac's Bluetooth discovery service (GATT status $status)."
    }
  )

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
