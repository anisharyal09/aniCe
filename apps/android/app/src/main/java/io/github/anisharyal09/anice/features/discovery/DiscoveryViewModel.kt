// SPDX-License-Identifier: GPL-3.0-or-later
// Owns bounded Bluetooth discovery and reports radio-work transitions independently of navigation.
package io.github.anisharyal09.anice.features.discovery

import android.Manifest
import android.annotation.SuppressLint
import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import io.github.anisharyal09.anice.infrastructure.bluetooth.AndroidBleCentralAdapter
import io.github.anisharyal09.anice.infrastructure.bluetooth.CentralDiscoverySession
import io.github.anisharyal09.anice.infrastructure.bluetooth.ConnectionStage
import io.github.anisharyal09.anice.infrastructure.bluetooth.DiscoverySnapshot
import io.github.anisharyal09.anice.infrastructure.bluetooth.DiscoveryState
import io.github.anisharyal09.anice.infrastructure.bluetooth.RecoveryReason

class DiscoveryViewModel(application: Application) : AndroidViewModel(application) {
    private val context
        get() = getApplication<Application>()

    private val session =
        CentralDiscoverySession(
            AndroidBleCentralAdapter(this.context),
            SystemClock::elapsedRealtime,
        )
    var state by mutableStateOf(DiscoverySnapshot())
        private set

    var awaitingPermissions = false
        private set

    var onBusyChanged: (Boolean) -> Unit = {}

    private var foreground = false
    private val handler = Handler(Looper.getMainLooper())
    private val ticker =
        object : Runnable {
            override fun run() {
                if (state.busy) {
                    if (
                        state.stage != ConnectionStage.disconnecting &&
                            !awaitingPermissions &&
                            !available()
                    )
                        return
                    session.tick()
                }
                if (state.busy) handler.postDelayed(this, 100)
            }
        }
    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == Intent.ACTION_SCREEN_OFF) releaseForBackground()
                else if (state.busy) {
                    available()
                    schedule()
                }
            }
        }

    init {
        session.onChange = {
            val wasBusy = state.busy
            state = it
            if (wasBusy != it.busy) onBusyChanged(it.busy)
        }
        ContextCompat.registerReceiver(
            context,
            receiver,
            IntentFilter().apply {
                addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(LocationManager.MODE_CHANGED_ACTION)
            },
            ContextCompat.RECEIVER_EXPORTED,
        )
    }

    fun missingPermissions(): Array<String> {
        val needed =
            if (Build.VERSION.SDK_INT >= 31)
                arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        return needed
            .filter {
                ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
            }
            .toTypedArray()
    }

    fun permissionsToRequest(): Array<String> {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            available()
            return emptyArray()
        }
        return missingPermissions()
    }

    fun permissionRequestStarted() {
        awaitingPermissions = true
    }

    fun permissionsReturned(permanentlyDenied: Boolean) {
        if (!awaitingPermissions) return
        awaitingPermissions = false
        if (missingPermissions().isEmpty()) {
            if (foreground) start()
        } else
            session.unavailable(
                DiscoveryState.permissionNeeded,
                if (permanentlyDenied) RecoveryReason.permanentDenial
                else RecoveryReason.permission,
                "Allow Bluetooth discovery access to find your Mac.",
            )
    }

    @SuppressLint("MissingPermission")
    private fun available(): Boolean =
        try {
            checkAvailable()
        } catch (_: SecurityException) {
            session.unavailable(
                DiscoveryState.permissionNeeded,
                RecoveryReason.permission,
                "Bluetooth permission changed. Allow access and try again.",
            )
            schedule()
            false
        }

    @SuppressLint("MissingPermission")
    private fun checkAvailable(): Boolean {
        val reason: RecoveryReason
        val message: String
        val state: DiscoveryState
        when {
            !context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) -> {
                reason = RecoveryReason.unsupported
                message = "Bluetooth LE discovery is unavailable on this device."
                state = DiscoveryState.failed
            }
            missingPermissions().isNotEmpty() -> {
                reason = RecoveryReason.permission
                message =
                    "Allow Nearby Devices access (or location on Android 10–11) to scan for your Mac."
                state = DiscoveryState.permissionNeeded
            }
            context.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled != true -> {
                reason = RecoveryReason.bluetoothDisabled
                message = "Turn on Bluetooth, then scan again."
                state = DiscoveryState.bluetoothOff
            }
            Build.VERSION.SDK_INT <= 30 &&
                context.getSystemService(LocationManager::class.java)?.isLocationEnabled !=
                    true -> {
                reason = RecoveryReason.locationServicesDisabled
                message = "Turn on location services for Bluetooth scanning on Android 10–11."
                state = DiscoveryState.permissionNeeded
            }
            else -> return true
        }
        session.unavailable(state, reason, message)
        // Keep scheduling cleanup when permission/radio loss happens during GATT work.
        if (this.state.busy) schedule()
        return false
    }

    private fun schedule() {
        handler.removeCallbacks(ticker)
        if (state.busy) handler.postDelayed(ticker, 100)
    }

    var beforeStart: () -> Unit = {}

    fun start() {
        if (foreground && available()) {
            beforeStart()
            session.start()
            schedule()
        }
    }

    fun select(rowId: Long) {
        if (available()) {
            session.select(rowId)
            schedule()
        }
    }

    fun cancel() {
        awaitingPermissions = false
        session.cancel()
        schedule()
    }

    fun foreground() {
        foreground = true
    }

    fun background() {
        foreground = false
        if (!awaitingPermissions) releaseForBackground()
    }

    private fun releaseForBackground() {
        cancel()
        // A suspended process cannot guarantee a delayed timer; close immediately on foreground
        // exit.
        session.retire()
        schedule()
    }

    override fun onCleared() {
        handler.removeCallbacks(ticker)
        context.unregisterReceiver(receiver)
        session.retire()
    }
}
