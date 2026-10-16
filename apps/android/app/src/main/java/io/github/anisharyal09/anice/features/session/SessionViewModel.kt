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
    val findDevice = (application as AniCeApplication).findDevice
    val media = (application as AniCeApplication).nowPlaying
    val transfer = (application as AniCeApplication).transfer
    val lan = (application as AniCeApplication).lanSessionController
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

    fun permissionReturned() = owner.permissionReturned()

    fun connect(peer: DeviceIdentity) = owner.connect(peer)

    fun checkConnection() = owner.checkConnection()

    fun disconnect() {
        owner.disconnect()
        lan.disconnect()
    }

    fun disconnectBluetooth() = owner.disconnect()

    fun cancelBluetooth() = owner.cancel()

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
