// SPDX-License-Identifier: GPL-3.0-or-later
// Exposes shared transport state and retires both channels on device-level cancellation.
package io.github.anisharyal09.anice.features.session

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity

typealias ConnectionState = io.github.anisharyal09.anice.infrastructure.connections.ConnectionState

/**
 * Exposes the shared owner's observable state without copying it into a second connection model.
 * ViewModel clearing drops UI callbacks; only the owner decides whether a companion lease retains
 * work.
 */
class SessionViewModel(application: Application) : AndroidViewModel(application) {
    private val owner = (application as AniCeApplication).sessionController
    val clipboard = (application as AniCeApplication).clipboard
    val sms = (application as AniCeApplication).sms
    val phoneInput = (application as AniCeApplication).phoneInput
    val devicePower = (application as AniCeApplication).devicePower
    val deskDeck = (application as AniCeApplication).deskDeck
    val findDevice = (application as AniCeApplication).findDevice
    val media = (application as AniCeApplication).nowPlaying
    val audioSharing = (application as AniCeApplication).audioSharing
    val phoneAudio = (application as AniCeApplication).phoneAudio
    val transfer = (application as AniCeApplication).transfer
    val lan = (application as AniCeApplication).lanSessionController
    val connectionPause = (application as AniCeApplication).connectionPause
    val state
        get() = owner.state

    val status
        get() = owner.status

    val selected
        get() = owner.selected

    val receivedChecks
        get() = owner.receivedChecks

    var beforeConnect: () -> Unit
        get() = owner.beforeConnect
        set(value) {
            owner.beforeConnect = value
        }

    fun missingPermissions() = owner.missingPermissions()

    fun request(peer: DeviceIdentity) = owner.request(peer)
    val findingAutomatically get() = owner.findingAutomatically
    internal fun findTrustedForeground(peer: DeviceIdentity) = owner.findTrustedForeground(peer)
    internal fun requestAfterPairing(peer: DeviceIdentity,
        candidate: io.github.anisharyal09.anice.infrastructure.bluetooth.PairedBleCandidate?) =
        owner.requestAfterPairing(peer, candidate)

    /** Device-level Connect asks both transports; LAN declines without disturbing an existing peer session. */
    fun connectDevice(peer: DeviceIdentity) {
        owner.request(peer)
        lan.connectAlongside(peer)
    }

    fun permissionReturned() = owner.permissionReturned()

    fun connect(peer: DeviceIdentity) = owner.connect(peer)

    fun checkConnection() = owner.checkConnection()

    fun disconnect() {
        owner.disconnect()
        lan.disconnect()
    }

    fun disconnectBluetooth() = owner.disconnect()

    fun cancelBluetooth() = owner.cancel()

    fun cancelBluetoothAttempt() = owner.cancelAttempt()

    /** Cancel stops only the in-flight attempt; automatic preferences remain armed. */
    fun cancelConnect() {
        owner.cancelAttempt()
        lan.cancelAttempt()
    }

    fun cancel() {
        owner.cancel()
        lan.cancel()
    }

    fun foreground(presentation: Any) {
        media.foreground(presentation)
        owner.foreground(presentation)
        lan.foreground(presentation)
    }

    fun background(presentation: Any, changingConfigurations: Boolean) {
        media.background(presentation, changingConfigurations)
        owner.background(presentation, changingConfigurations)
        lan.background(presentation, changingConfigurations)
    }

    override fun onCleared() = owner.presentationCleared()

    companion object {
        val CHECK
            get() = io.github.anisharyal09.anice.infrastructure.connections.SessionController.CHECK
    }
}
