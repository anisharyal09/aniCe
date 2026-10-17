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
 */
internal fun transferLeases(
    activeTransport: String?,
    connecting: Boolean,
    backgroundAllowed: Boolean,
    selectingFiles: Boolean,
    bleSecured: Boolean,
): TransferLeases = TransferLeases(
    lanWork = backgroundAllowed && (activeTransport == "lan" || connecting),
    lanPicker = selectingFiles,
    bleWork = backgroundAllowed && (activeTransport == "ble" || (activeTransport == null && bleSecured)),
    blePicker = selectingFiles && bleSecured,
)
