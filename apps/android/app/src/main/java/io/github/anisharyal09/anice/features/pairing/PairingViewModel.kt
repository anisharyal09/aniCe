// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinates pairing transport, worker-confined authentication and main-thread presentation.
package io.github.anisharyal09.anice.features.pairing

import android.Manifest
import android.annotation.SuppressLint
import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.*
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.*
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.bluetooth.AndroidPairingTransport
import io.github.anisharyal09.anice.infrastructure.bluetooth.PairingTransportFailure
import io.github.anisharyal09.anice.infrastructure.bluetooth.PairingTransportRecovery
import io.github.anisharyal09.anice.infrastructure.bluetooth.NearbyPairingCandidate
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.pairing.*
import java.io.File
import java.util.concurrent.Executors
import io.github.anisharyal09.anice.infrastructure.connections.PeerNickname
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch

class PairingViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as AniCeApplication
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    // Retired worker results must not update a replacement invitation or send on its transport.
    @Volatile private var generation = 0L
    private var engine: PairingEngine? = null
    private var store: PeerTrustStore? = null
    internal var method by mutableStateOf(PairingMethod.QR)
        private set
    private var invitation: PairingQR? = null
    private var code = ""
    var savingNickname by mutableStateOf(false)
        private set
    var nicknameFailure by mutableStateOf(false)
        private set
    internal fun nickname(peer: DeviceIdentity) = app.peerNames.nickname(peer)
    fun displayedName(peer: DeviceIdentity) = app.peerNames.displayName(peer)
    fun deviceName(peer: DeviceIdentity) = app.peerNames.deviceName(peer)
    fun saveNickname(peer: DeviceIdentity, name: String, enabled: Boolean) {
        if (savingNickname || peers.none {
                it.peer.deviceId == peer.deviceId && it.peer.fingerprint == peer.fingerprint &&
                    it.peer.publicKey == peer.publicKey }) return
        savingNickname = true
        nicknameFailure = false
        viewModelScope.launch {
            try {
                app.peerNames.saveNickname(peer, name, enabled)
            } catch (_: Exception) { nicknameFailure = true }
            finally { savingNickname = false }
        }
    }
    private var nearbyCandidate: NearbyPairingCandidate? = null
    private var pairedCandidate: io.github.anisharyal09.anice.infrastructure.bluetooth.PairedBleCandidate? = null
    internal fun takePairedCandidate(): io.github.anisharyal09.anice.infrastructure.bluetooth.PairedBleCandidate? {
        if (phase != "paired") return null
        return pairedCandidate.also { pairedCandidate = null }
    }
    var automaticAfterPairing by mutableStateOf(true)
        private set
    fun chooseAutomaticAfterPairing(enabled: Boolean) {
        if (phase == "comparison") automaticAfterPairing = enabled
    }
    var comparisonCode by mutableStateOf<String?>(null)
        private set
    var comparisonAttempt by mutableStateOf(0L)
        private set
    var completedWithComparison by mutableStateOf(false)
        private set
    val comparingNearby get() = method == PairingMethod.SAS && busy
    val nearbyFailure get() = method == PairingMethod.SAS && phase == "failed"
    var nearbyTransportFailure by mutableStateOf(false)
        private set
    var phase by mutableStateOf("idle")
        private set

    var status by mutableStateOf("Scan the QR code on your Mac, or enter its six-digit code.")
        private set

    var rows by mutableStateOf(listOf<Long>())
        private set

    var peer by mutableStateOf<DeviceIdentity?>(null)
        private set

    var peers by mutableStateOf(listOf<PeerTrustRecord>())
        private set

    var trustedPeersLoaded by mutableStateOf(false)
        private set

    var recovery by mutableStateOf("")
        private set

    var remaining by mutableStateOf(0)
        private set

    var awaitingPermissions = false
        private set

    val busy
        get() = phase !in listOf("idle", "failed", "paired")

    var beforePairing: () -> Unit = {}
    var trustRemoved: () -> Unit = {}
    var onPeersChanged: (List<PeerTrustRecord>) -> Unit = {}
    private var foreground = false
    private var overall = 0L
    private var deadline = 0L
    private var readyToFinish = false
    private var rejectingComparison = false
    @Volatile private var trustedPeerIdsBeforePairing = emptySet<String>()
    private var connectionStep = "connecting"
    private val transport =
        AndroidPairingTransport(
            app,
            { rows = rows + it },
            { onConnected() },
            { receive(it) },
            { success, reason ->
                if (rejectingComparison) cancel()
                else if (readyToFinish && success) {
                    finishPairing()
                } else if (busy) failLink(reason)
            },
            { step, expires ->
                connectionStep = step
                rows = if (step == "scan") rows else emptyList()
                phase = if (step == "scan") "scan" else "connecting"
                deadline = expires
                status =
                    when (step) {
                        "scan" ->
                            if (method == PairingMethod.QR) "Finding your QR invitation…"
                            else "Select the Mac displaying your six-digit code."
                        "mtu" -> "Opening the Bluetooth connection…"
                        "services" -> "Looking for the Mac’s pairing service…"
                        "subscribe" -> "Opening the Mac’s reply channel…"
                        "checking" -> "Checking the pairing invitation…"
                        else -> "Connecting to nearby Mac…"
                    }
                scheduleComparisonDeadline()
            },
        )
    val choosingCandidate
        get() = method == PairingMethod.PIN && phase == "scan"

    private val ticker =
        object : Runnable {
            override fun run() {
                if (!busy) return
                val now = SystemClock.elapsedRealtime()
                remaining =
                    (((minOf(overall, deadline) - now).coerceAtLeast(0) + 999) / 1000).toInt()
                if (now >= overall || now >= deadline) {
                    if (rejectingComparison) cancel()
                    else if (phase == "cleanup" && readyToFinish) {
                        transport.close()
                        finishPairing()
                    } else if (phase == "scan" && transport.scanEndFailure != null) {
                        failLink(transport.scanEndFailure)
                    } else
                        fail(
                            when {
                                phase == "scan" -> "Scan ended. Scan again to find nearby devices."
                                phase == "connecting" ->
                                    when (connectionStep) {
                                        "services" ->
                                            "The Mac did not finish service discovery. Show a fresh pairing invitation and try again."
                                        "subscribe" ->
                                            "The Mac did not open its pairing reply channel. Show a fresh invitation and try again."
                                        "checking" ->
                                            "The Mac did not answer the invitation check. Show a fresh QR code or six-digit code and try again."
                                        else ->
                                            "Bluetooth could not connect to your Mac. Keep the invitation open and try again."
                                    }
                                else -> "Pairing timed out. Start a fresh invitation."
                            }
                        )
                    return
                }
                handler.postDelayed(this, if (method == PairingMethod.SAS)
                    (minOf(overall, deadline) - now).coerceAtLeast(1) else 200)
            }
        }
    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                if (i?.action == Intent.ACTION_SCREEN_OFF) background(true)
                else if (busy && !awaitingPermissions && !available())
                    fail("Bluetooth availability changed. Start again.")
            }
        }

    init {
        ContextCompat.registerReceiver(
            app,
            receiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
                addAction(LocationManager.MODE_CHANGED_ACTION)
            },
            ContextCompat.RECEIVER_EXPORTED,
        )
        refresh()
    }

    fun missingPermissions(): Array<String> {
        val permissions =
            if (Build.VERSION.SDK_INT >= 31)
                arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        return permissions
            .filter {
                ContextCompat.checkSelfPermission(app, it) != PackageManager.PERMISSION_GRANTED
            }
            .toTypedArray()
    }

    fun cameraUnavailable() {
        status =
            "Camera access is unavailable. Allow camera access in Settings or use the six-digit code."
    }

    fun beginQR(text: String) {
        try {
            val qr = PairingQR.decode(text)
            cancel()
            method = PairingMethod.QR
            completedWithComparison = false
            invitation = qr
            phase = "permission"
            status = "Ready to find the QR invitation."
        } catch (_: Exception) {
            status = "This is not a valid aniCe pairing QR code."
            phase = "failed"
        }
    }

    fun beginPIN(pin: String) {
        if (!pin.matches(Regex("[0-9]{6}"))) {
            status = "Enter all six digits, including any leading zeros."
            return
        }
        cancel()
        method = PairingMethod.PIN
        completedWithComparison = false
        code = pin
        phase = "permission"
        status = "Ready to scan for your Mac."
    }

    internal fun beginNearby(candidate: NearbyPairingCandidate) {
        if (!foreground) { candidate.discard(); return }
        cancel()
        method = PairingMethod.SAS
        comparisonAttempt = generation
        nearbyCandidate = candidate
        completedWithComparison = false
        nearbyTransportFailure = false
        phase = "permission"
        status = "Preparing a nearby comparison…"
        start()
    }

    fun permissionStarted() {
        awaitingPermissions = true
    }

    fun permissionReturned(permanent: Boolean) {
        if (!awaitingPermissions) return
        awaitingPermissions = false
        if (missingPermissions().isEmpty()) {
            if (foreground) start()
        } else {
            phase = "failed"
            recovery = if (permanent) "settings" else "permission"
            status = "Allow Nearby Devices access (location on Android 10–11), then start again."
        }
    }

    @SuppressLint("MissingPermission")
    private fun available(): Boolean =
        try {
            checkAvailable()
        } catch (_: SecurityException) {
            recovery = "permission"
            status = "Bluetooth permission changed. Allow access and start again."
            false
        }

    @SuppressLint("MissingPermission")
    private fun checkAvailable(): Boolean {
        recovery = ""
        when {
            !app.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) -> {
                status = "Bluetooth LE is unavailable on this device."
                recovery = "unsupported"
            }
            missingPermissions().isNotEmpty() -> {
                status = "Allow Bluetooth discovery access to pair."
                recovery = "permission"
            }
            app.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled != true -> {
                status = "Turn on Bluetooth and try again."
                recovery = "bluetooth"
            }
            Build.VERSION.SDK_INT <= 30 &&
                app.getSystemService(LocationManager::class.java)?.isLocationEnabled != true -> {
                status = "Turn on location services for scanning on Android 10–11."
                recovery = "location"
            }
            else -> return true
        }
        return false
    }

    fun start() {
        if (!foreground || phase != "permission") return
        if (!available()) {
            phase = "failed"
            return
        }
        beforePairing()
        val op = generation
        val selectedCandidate = nearbyCandidate
        val selectedMethod = method
        phase = "preparing"
        status = "Preparing pairing…"
        rows = emptyList()
        readyToFinish = false
        rejectingComparison = false
        if (selectedMethod == PairingMethod.SAS) {
            overall = SystemClock.elapsedRealtime() + 120000
            deadline = SystemClock.elapsedRealtime() + 15000
            scheduleComparisonDeadline()
        }
        worker.execute {
            try {
                val trust = store ?: app.trustStore.also { store = it }
                val trustedPeerIds = trust.list(
                    app.identityService.getOrCreateIdentity().identity.fingerprint
                ).map { it.peer.deviceId }.toSet()
                if (generation != op) return@execute
                if (selectedMethod == PairingMethod.SAS) require(trustedPeerIds.isEmpty())
                trustedPeerIdsBeforePairing = trustedPeerIds
                val created =
                    PairingEngine(
                        selectedMethod,
                        invitation,
                        code.toByteArray(),
                        app.identityService,
                        trust,
                        { data ->
                            handler.post { if (generation == op && busy) transport.send(data) }
                        },
                        { state, p -> handler.post { if (generation == op) event(state, p) } },
                        { digits -> handler.post {
                            if (generation == op && foreground) {
                                comparisonCode = digits
                                comparisonAttempt = op
                            }
                        } },
                        { generation == op },
                    )
                if (generation != op) {
                    created.close()
                    return@execute
                }
                engine = created
                handler.post {
                    if (generation == op && foreground) {
                        phase = "scan"
                        status =
                            if (method == PairingMethod.QR)
                                "Finding the Mac matching your QR invitation…"
                            else "Select the Mac displaying your code."
                        if (selectedMethod != PairingMethod.SAS)
                            overall = SystemClock.elapsedRealtime() + 120000
                        deadline = SystemClock.elapsedRealtime() + 15000
                        if (selectedMethod == PairingMethod.SAS) {
                            phase = "connecting"
                            status = "Opening the nearby Mac’s comparison channel…"
                            try {
                                requireNotNull(selectedCandidate).connect(transport)
                                nearbyCandidate = null
                            } catch (_: Exception) {
                                fail("Nearby device expired. Choose Try again to find your Mac.")
                                return@post
                            }
                        } else transport.startScan(selectedMethod == PairingMethod.QR)
                        if (selectedMethod == PairingMethod.SAS) scheduleComparisonDeadline()
                        else handler.post(ticker)
                    }
                }
            } catch (error: Exception) {
                handler.post {
                    if (generation == op) {
                        if (error is TrustStoreCorruptException) recovery = "trustStore"
                        fail(
                            if (error is TrustStoreCorruptException)
                                "Local trust records could not be verified. Reset local trust to pair again."
                            else "Pairing could not start. Check identity access and try again."
                        )
                    }
                }
            }
        }
    }

    fun select(id: Long) {
        if (choosingCandidate) {
            rows = emptyList()
            phase = "connecting"
            status = "Connecting to nearby device…"
            deadline = SystemClock.elapsedRealtime() + 15000
            transport.select(id)
        }
    }

    private fun onConnected() {
        phase = "connecting"
        status = "Checking the pairing invitation…"
        deadline = SystemClock.elapsedRealtime() + 10000
        rows = emptyList()
        transport.send(PairingCodec.message(1))
        scheduleComparisonDeadline()
    }

    private fun receive(data: ByteArray) {
        if (phase == "cancelling" || rejectingComparison) return
        val op = generation
        if (data.firstOrNull() == 2.toByte() && method == PairingMethod.QR) {
            try {
                val f = PairingCodec.unpack(data, 2, 3)
                require(f[0].size == 1 && f[1].size == 16 && f[2].size == 32)
                if (
                    f[0].contentEquals(byteArrayOf(1)) && f[1].contentEquals(invitation?.rendezvous)
                )
                    transport.matched()
                else {
                    if (!transport.nextCandidate())
                        fail(
                            "No nearby Mac matched this invitation. Show a fresh QR code and try again."
                        )
                    return
                }
            } catch (_: Exception) {
                fail("The invitation response was invalid.")
                return
            }
        }
        worker.execute {
            if (generation != op) return@execute
            try {
                engine?.receive(data) ?: throw PairingException()
            } catch (_: Exception) {
                handler.post {
                    if (generation == op)
                        fail("Authentication failed or the invitation expired. Start again.")
                }
            }
        }
        scheduleComparisonDeadline()
    }

    private fun scheduleComparisonDeadline() {
        if (method != PairingMethod.SAS || !busy || overall == 0L) return
        handler.removeCallbacks(ticker)
        val now = SystemClock.elapsedRealtime()
        remaining = (((minOf(overall, deadline) - now).coerceAtLeast(0) + 999) / 1000).toInt()
        handler.postDelayed(ticker, (minOf(overall, deadline) - now).coerceAtLeast(1))
    }

    private fun event(state: String, p: DeviceIdentity?) {
        android.util.Log.i("aniCe-pairing", "pairing_state operation=$generation method=${method.wire} from=$phase to=$state")
        peer = p
        phase = state
        when (state) {
            "cancelled" -> {
                fail("Pairing was cancelled on your Mac. Start again when ready.")
            }
            "authenticating" -> {
                status = "Authenticating your Mac…"
                deadline = SystemClock.elapsedRealtime() + 30000
            }
            "approval" -> {
                status = "Verify this Mac, then approve pairing on both devices."
                deadline = SystemClock.elapsedRealtime() + 60000
            }
            "comparison" -> {
                status = "Compare all six digits on your Mac, then confirm on both devices."
                deadline = SystemClock.elapsedRealtime() + 60000
            }
            "verifying" -> {
                status = "Both confirmed. Verifying device identities…"
                deadline = SystemClock.elapsedRealtime() + 30000
            }
            "saving" -> {
                status = "Saving trust and confirming peer storage…"
                deadline = SystemClock.elapsedRealtime() + 10000
            }
            "paired" -> {
                if (p != null) pairedCandidate = transport.pairedCandidate(p)
                readyToFinish = true
                phase = "cleanup"
                status = "Trust saved. Releasing Bluetooth…"
                deadline = SystemClock.elapsedRealtime() + 2000
                transport.finishAfterWrites()
            }
        }
        scheduleComparisonDeadline()
    }

    fun approve() {
        if (phase != "approval") return
        phase = "waiting"
        status = "Approved here. Waiting for your Mac…"
        val op = generation
        worker.execute {
            if (generation == op)
                try {
                    engine?.approve()
                } catch (_: Exception) {
                    handler.post {
                        if (generation == op) fail("Could not save pairing. Start again.")
                    }
                }
        }
    }

    fun confirmComparison(attempt: Long) {
        android.util.Log.i("aniCe-pairing", "comparison_confirm operation=$generation current=${attempt == comparisonAttempt && generation == attempt} phase=$phase")
        if (attempt != comparisonAttempt || generation != attempt || phase != "comparison" ||
            comparisonCode == null || method != PairingMethod.SAS) return
        val now = SystemClock.elapsedRealtime()
        if (!foreground || app.getSystemService(android.app.KeyguardManager::class.java)?.isKeyguardLocked == true ||
            now >= minOf(overall, deadline)) {
            fail("Comparison expired or the phone was locked. Start a fresh pairing.")
            return
        }
        phase = "waiting"
        status = "Confirmed here. Waiting for your Mac…"
        worker.execute {
            if (generation != attempt) return@execute
            try { engine?.confirmComparison() } catch (_: Exception) {
                handler.post { if (generation == attempt) fail("Comparison could not finish. Start again.") }
            }
        }
    }

    fun declineComparison(attempt: Long = comparisonAttempt) {
        if (attempt != comparisonAttempt || generation != attempt) return
        if (!comparingNearby || phase in listOf("saving", "cleanup", "cancelling")) return
        android.util.Log.i("aniCe-pairing", "comparison_dismiss operation=$generation phase=$phase")
        val op = ++generation
        phase = "cancelling"
        status = "Dismissing pairing…"
        worker.execute {
            if (generation != op) return@execute
            val cancellation = try { engine?.cancellation() } catch (_: Exception) { null }
            engine = null
            handler.post {
                if (generation != op) return@post
                rejectingComparison = true
                phase = "cleanup"
                deadline = SystemClock.elapsedRealtime() + 2000
                if (cancellation != null) transport.send(cancellation)
                transport.finishAfterWrites()
                scheduleComparisonDeadline()
            }
        }
    }

    fun cancel() {
        nearbyTransportFailure = false
        generation++
        handler.removeCallbacks(ticker)
        if (foreground) transport.cancel() else transport.close()
        retireEngine()
        invitation?.secret?.fill(0)
        invitation = null
        code = ""
        nearbyCandidate?.discard()
        nearbyCandidate = null
        pairedCandidate?.discard()
        pairedCandidate = null
        comparisonCode = null
        rows = emptyList()
        remaining = 0
        peer = null
        phase = "idle"
        status = "Pairing stopped. Start again when ready."
        awaitingPermissions = false
        readyToFinish = false
        rejectingComparison = false
    }

    private fun retireEngine() {
        worker.execute {
            try {
                engine?.close()
            } catch (_: Exception) {}
            engine = null
        }
    }

    private fun finishPairing() {
        if (phase == "paired") return
        peer?.takeIf { it.deviceId !in trustedPeerIdsBeforePairing }
            ?.let(app.transfer.autoReceivePreferences::enableForNewPeer)
        phase = "paired"
        completedWithComparison = method == PairingMethod.SAS
        status = "Pairing complete. Device saved as trusted."
        retireEngine()
        refresh()
    }

    private fun failLink(failure: PairingTransportFailure?) {
        val beforeAuthentication = method == PairingMethod.SAS && phase in listOf("scan", "connecting")
        if (failure?.recovery == PairingTransportRecovery.bluetoothSettings) recovery = "bluetooth"
        fail(failure?.message ?: "Pairing was interrupted. Start again.")
        nearbyTransportFailure = beforeAuthentication && failure?.recovery != PairingTransportRecovery.bluetoothSettings
    }

    private fun fail(message: String) {
        val oldRecovery = recovery
        cancel()
        phase = "failed"
        status = message
        recovery = oldRecovery
    }

    fun foreground() {
        foreground = true
        // Screen lock/background can retire the initial asynchronous trust load before delivery.
        // Recheck on return; otherwise first-setup discovery remains silently ineligible forever.
        if (!trustedPeersLoaded) refresh()
    }

    fun background(screenOff: Boolean = false) {
        foreground = false
        if (screenOff || !awaitingPermissions) cancel()
    }

    fun refresh() {
        trustedPeersLoaded = false
        val op = generation
        worker.execute {
            try {
                val local = app.identityService.getOrCreateIdentity().identity
                val trust = store ?: app.trustStore.also { store = it }
                val list = trust.list(local.fingerprint)
                handler.post {
                    if (generation == op) {
                        peers = list
                        app.peerNames.refresh()
                        trustedPeersLoaded = true
                        onPeersChanged(list)
                    }
                }
            } catch (error: Exception) {
                handler.post {
                    if (generation == op) {
                        recovery = if (error is TrustStoreCorruptException) "trustStore" else ""
                        status =
                            if (error is TrustStoreCorruptException)
                                "Local trust records could not be verified. Reset local trust to pair again."
                            else "Trusted devices are unavailable. Check identity access."
                    }
                }
            }
        }
    }

    fun recoverTrustStore() {
        cancel()
        val op = generation
        worker.execute {
            try {
                store = PeerTrustStore.recover(File(app.noBackupFilesDir, "trusted_peers.json"))
                app.trustStore = requireNotNull(store)
                handler.post {
                    if (op == generation) {
                        recovery = ""
                        trustRemoved()
                        peers = emptyList()
                        trustedPeersLoaded = true
                        onPeersChanged(emptyList())
                        status =
                            "Local trust was reset. Pair your devices again. The unreadable file was preserved."
                    }
                }
            } catch (_: Exception) {
                handler.post {
                    if (op == generation) status = "Could not recover local trust. Try again."
                }
            }
        }
    }

    fun forget(id: String) {
        worker.execute {
            try {
                store?.remove(id)
                handler.post { trustRemoved() }
                refresh()
            } catch (_: Exception) {
                handler.post { status = "Could not remove local trust. Try again." }
            }
        }
    }

    override fun onCleared() {
        cancel()
        app.unregisterReceiver(receiver)
        worker.shutdown()
    }
}
