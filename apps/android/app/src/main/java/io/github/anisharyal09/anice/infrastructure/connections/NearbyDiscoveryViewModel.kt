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
    var status by mutableStateOf("Getting ready to find your Mac…")
        private set
    var scanning by mutableStateOf(false)
        private set
    var dismissed by mutableStateOf(false)
        private set
    var paused by mutableStateOf(false)
        private set
    var choosingCandidate by mutableStateOf(false)
        private set
    private val app = application
    private val permissionPreferences = app.getSharedPreferences("nearby_permission", Context.MODE_PRIVATE)
    private var permissionRequested = permissionPreferences.getBoolean("requested", false)
    var permissionRequired by mutableStateOf(false)
        private set
    var permissionNeedsSettings by mutableStateOf(permissionPreferences.getBoolean("settings", false))
        private set
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
    private var scanBoost: Runnable? = null
    private val comparisonPolicy = NearbyComparisonPolicy()
    private var pendingComparison: Long? = null
    private val automaticComparison = Runnable {
        pendingComparison = null
        val listener = onUnambiguousCandidate ?: return@Runnable
        reconcile()
        publish()
        if (!scanning || paused) return@Runnable
        val id = comparisonPolicy.candidate(candidates.map { it.id }, eligible && foreground, dismissed)
        if (id != null) listener(id)
    }
    internal var onUnambiguousCandidate: ((Long) -> Unit)? = null
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
    /** Called only by resumed Home; the OS grants access, not discovery or trust. */
    internal fun initialPermissionRequest(previouslyDenied: Boolean): Array<String> {
        val missing = missingPermissions()
        val allowed = foreground && eligible && !paused && !dismissed &&
            app.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) &&
            app.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked != true
        if (!initialNearbyPermissionReady(allowed, missing.isNotEmpty(), permissionRequested, previouslyDenied))
            return emptyArray()
        permissionRequestStarted()
        return missing
    }
    internal fun permissionRequestStarted() {
        permissionRequested = true
        permissionPreferences.edit().putBoolean("requested", true).apply()
    }
    internal fun permissionsReturned(permanent: Boolean) {
        permissionNeedsSettings = permanent && missingPermissions().isNotEmpty()
        permissionPreferences.edit().putBoolean("settings", permissionNeedsSettings).apply()
        // A denied dialog is never permission to scan or to clear a dismissed comparison.
        reconcile()
    }
    fun dismiss() { dismissed = true; reconcile() }
    fun pause() { paused = true; reconcile() }
    fun retry() {
        comparisonPolicy.reset()
        choosingCandidate = false
        dismissed = false; paused = false; failed = false; reconcile()
        if (scanning) publish()
    }
    /** Selection freezes one current handle and retires scanning before cryptographic preparation. */
    internal fun claim(id: Long): NearbyPairingCandidate? {
        reconcile()
        publish()
        if (!foreground || !eligible || paused || dismissed || !scanning || candidates.none { it.id == id }) return null
        val device = devices[id] ?: return null
        val selected = NearbyPairingCandidate(device)
        dismissed = true
        stop()
        return selected
    }

    @SuppressLint("MissingPermission")
    private fun reconcile() {
        permissionRequired = missingPermissions().isNotEmpty()
        if (!permissionRequired && permissionNeedsSettings) {
            permissionNeedsSettings = false
            permissionPreferences.edit().putBoolean("settings", false).apply()
        }
        val available = try {
            foreground && eligible && !paused && !dismissed &&
                app.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked != true &&
                !permissionRequired &&
                app.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true &&
                (Build.VERSION.SDK_INT > 30 ||
                    app.getSystemService(LocationManager::class.java)?.isLocationEnabled == true)
        } catch (_: SecurityException) { false }
        if (!available) {
            stop()
            status = when {
                dismissed -> "Nearby comparison closed. Find nearby when you're ready."
                paused -> "Nearby discovery paused."
                !foreground || !eligible -> "Getting ready to find your Mac…"
                permissionRequired -> if (Build.VERSION.SDK_INT >= 31)
                    "Allow nearby devices so aniCe can find your Mac automatically."
                    else "Allow location access for Bluetooth discovery on Android 10–11."
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
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), cb)
            // Fast foreground entry, then lower radio cost. This never extends into background.
            scanBoost = Runnable {
                if (generation == operation && callback === cb && scanning) {
                    try {
                        scanner?.stopScan(cb)
                        scanner?.startScan(listOf(ScanFilter.Builder().setServiceUuid(
                            ParcelUuid(UUID.fromString(BlePayloadCodec.SERVICE_UUID))).build()),
                            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).build(), cb)
                    } catch (_: Exception) { stop(); failed = true; status = "Bluetooth discovery interrupted. Try again." }
                }
            }.also { handler.postDelayed(it, 15_000) }
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
        if (candidates.size > 1) {
            comparisonPolicy.candidate(candidates.map { it.id }, eligible && foreground, dismissed)
            choosingCandidate = true
        }
        val single = candidates.singleOrNull()?.id
        if (single == null || dismissed || choosingCandidate || pendingComparison != null && pendingComparison != single) {
            handler.removeCallbacks(automaticComparison)
            pendingComparison = null
        }
        if (single != null && !dismissed && scanning && comparisonPolicy.allowsAutomatic && pendingComparison == null) {
            pendingComparison = single
            handler.postDelayed(automaticComparison, 750)
        }
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
        handler.removeCallbacks(automaticComparison)
        scanBoost?.let(handler::removeCallbacks); scanBoost = null
        pendingComparison = null
        handles.clear(); devices.clear(); filter.clear(); candidates = emptyList()
    }
    override fun onCleared() { stop(); app.unregisterReceiver(receiver) }
}
