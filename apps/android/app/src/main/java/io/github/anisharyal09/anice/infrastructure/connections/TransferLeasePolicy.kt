// SPDX-License-Identifier: GPL-3.0-or-later
// Decides which transport leases a transfer owns without depending on UI or connection state.
package io.github.anisharyal09.anice.infrastructure.connections

internal data class TransferLeases(
    val lanWork: Boolean,
    val lanPicker: Boolean,
    val bleWork: Boolean,
    val blePicker: Boolean,
)

/**
 * Picker leases follow the transports that are actually secured, not the transfer's currently
 * selected channel. Opening the document picker stops the Activity; without the BLE lease a
 * null or temporarily LAN-selected transfer channel would retire a healthy companion session.
 *
 * A secured BLE session also keeps its work lease while a batch is active or paused, because it is
 * the fallback that "Continue over Bluetooth" and a lost LAN depend on. Without it the session is
 * retired as soon as LAN becomes the active transport, and re-establishing it mid-batch shows up as
 * a connect/disconnect flicker with nothing moving.
 */
internal fun transferLeases(
    activeTransport: String?,
    connecting: Boolean,
    backgroundAllowed: Boolean,
    selectingFiles: Boolean,
    bleSecured: Boolean,
    paused: Boolean = false,
    busy: Boolean = false,
): TransferLeases = TransferLeases(
    // A paused LAN batch keeps its LAN lease: automatic LAN is what makes resuming possible.
    lanWork = backgroundAllowed && (activeTransport == "lan" || connecting || paused),
    lanPicker = selectingFiles,
    bleWork = backgroundAllowed && (
        activeTransport == "ble" || (bleSecured && (activeTransport == null || busy || paused))
    ),
    blePicker = selectingFiles && bleSecured,
)
