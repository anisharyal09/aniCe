// SPDX-License-Identifier: GPL-3.0-or-later
// Owns foreground-only anonymous BLE scanning; never connects, authenticates or writes trust.
package io.github.anisharyal09.anice.infrastructure.connections

import android.Manifest
import android.annotation.SuppressLint
import android.app.Application
import android.app.KeyguardManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.*
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import io.github.anisharyal09.anice.infrastructure.bluetooth.BlePayloadCodec
import io.github.anisharyal09.anice.infrastructure.bluetooth.ProximitySignalFilter
import java.util.UUID
import android.bluetooth.BluetoothDevice
import io.github.anisharyal09.anice.infrastructure.bluetooth.NearbyPairingCandidate

class NearbyDiscoveryViewModel(application: Application) : AndroidViewModel(application) {
    data class Candidate(val id: Long, val rssi: Int)
    var candidates by mutableStateOf(emptyList<Candidate>())
        private set
    var status by mutableStateOf("Nearby discovery is paused.")
        private set
    var scanning by mutableStateOf(false)
        private set
    var dismissed by mutableStateOf(false)
        private set
    var paused by mutableStateOf(false)
        private set
    private val app = application
    private val handler = Handler(Looper.getMainLooper())
    private val filter = ProximitySignalFilter(SystemClock::elapsedRealtime)
    // Native addresses stay in this active scan's deduplication map, never in presentation or logs.
    private val handles = linkedMapOf<String, Long>()
    private val devices = mutableMapOf<Long, BluetoothDevice>()
    private var nextID = 0L
    private var scanner: BluetoothLeScanner? = null
    private var callback: ScanCallback? = null
    private var generation = 0L
    private var foreground = false
    private var eligible = false
    private var failed = false
    private val expiry = Runnable { publish() }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) foreground = false
            reconcile()
        }
    }

    init {
        ContextCompat.registerReceiver(app, receiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(LocationManager.MODE_CHANGED_ACTION)
        }, ContextCompat.RECEIVER_EXPORTED)
    }

    fun missingPermissions(): Array<String> =
        (if (Build.VERSION.SDK_INT >= 31)
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION))
            .filter { ContextCompat.checkSelfPermission(app, it) != PackageManager.PERMISSION_GRANTED }
            .toTypedArray()

    fun foreground(value: Boolean) {
        foreground = value
        if (value) failed = false
        reconcile()
    }
    fun eligible(value: Boolean) { eligible = value; reconcile() }
    fun dismiss() { dismissed = true }
    fun pause() { paused = true; reconcile() }
    fun retry() { dismissed = false; paused = false; failed = false; reconcile() }
    /** Selection freezes one current handle and retires scanning before cryptographic preparation. */
    internal fun claim(id: Long): NearbyPairingCandidate? {
        publish()
        if (!foreground || !eligible || paused || !scanning || candidates.none { it.id == id }) return null
        val device = devices[id] ?: return null
        val selected = NearbyPairingCandidate(device)
        dismissed = true
        stop()
        return selected
    }

    @SuppressLint("MissingPermission")
    private fun reconcile() {
        val available = try {
            foreground && eligible && !paused &&
                app.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked != true &&
                missingPermissions().isEmpty() &&
                app.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true &&
                (Build.VERSION.SDK_INT > 30 ||
                    app.getSystemService(LocationManager::class.java)?.isLocationEnabled == true)
        } catch (_: SecurityException) { false }
        if (!available) {
            stop()
            status = when {
                !foreground || !eligible || paused -> "Nearby discovery is paused."
                missingPermissions().isNotEmpty() -> "Allow Nearby Devices access to find a Mac."
                else -> "Unlock your phone and turn on Bluetooth to find a Mac."
            }
        } else if (!scanning && !failed) start()
    }

    @SuppressLint("MissingPermission")
    private fun start() {
        val operation = ++generation
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handler.post {
                    if (generation != operation || callback !== this) return@post
                    if (app.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true) {
                        stop(); return@post
                    }
                    try {
                        val age = SystemClock.elapsedRealtimeNanos() - result.timestampNanos
                        if (age < 0 || age >= 5_000_000_000L) return@post
                        if (result.scanRecord?.serviceUuids?.contains(
                                ParcelUuid(UUID.fromString(BlePayloadCodec.SERVICE_UUID))) != true) return@post
                        val address = result.device.address
                        val id = handles[address] ?: run {
                            if (handles.size >= 32) return@post
                            (++nextID).also { handles[address] = it }
                        }
                        devices[id] = result.device
                        filter.observe(id, result.rssi)
                        publish()
                    } catch (_: SecurityException) {
                        stop(); failed = true; status = "Bluetooth permission changed. Find nearby again."
                    }
                }
            }
            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { onScanResult(0, it) }
            }
            override fun onScanFailed(errorCode: Int) {
                handler.post {
                    if (generation != operation || callback !== this) return@post
                    stop(); failed = true; status = "Nearby scanning could not start. Find nearby again."
                }
            }
        }
        try {
            scanner = app.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner
                ?: throw IllegalStateException("BLE unavailable")
            callback = cb
            scanning = true
            status = "Looking for a nearby Mac…"
            scanner!!.startScan(
                listOf(ScanFilter.Builder().setServiceUuid(
                    ParcelUuid(UUID.fromString(BlePayloadCodec.SERVICE_UUID))).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).build(), cb)
        } catch (_: Exception) {
            stop(); failed = true; status = "Nearby scanning is unavailable. Use manual pairing or try again."
        }
    }

    private fun publish() {
        val current = filter.current()
        val live = current.map { it.id }.toSet()
        handles.entries.removeAll { it.value !in live }
        devices.keys.retainAll(live)
        candidates = current.filter { it.nearby }.map { Candidate(it.id, it.rssi) }
        handler.removeCallbacks(expiry)
        filter.nextExpiry?.let { handler.postDelayed(expiry, (it - SystemClock.elapsedRealtime()).coerceAtLeast(1)) }
    }

    @SuppressLint("MissingPermission")
    private fun stop() {
        generation++
        val old = callback
        callback = null
        try { if (old != null) scanner?.stopScan(old) } catch (_: Exception) {}
        scanner = null
        scanning = false
        handler.removeCallbacks(expiry)
        handles.clear(); devices.clear(); filter.clear(); candidates = emptyList()
    }
    override fun onCleared() { stop(); app.unregisterReceiver(receiver) }
}
