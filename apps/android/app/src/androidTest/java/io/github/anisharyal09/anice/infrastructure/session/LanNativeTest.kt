// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies real network-bound TCP interoperability using disposable protected identities.
package io.github.anisharyal09.anice.infrastructure.session

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.AtomicFile
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.identity.*
import io.github.anisharyal09.anice.infrastructure.lan.*
import java.io.File
import java.net.Inet4Address
import java.net.Inet6Address
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.nio.ByteBuffer
import android.os.SystemClock
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanNativeTest {
    @Test
    fun rawSocketBaseline(): Unit = runBlocking(Dispatchers.IO) {
        val framed = InstrumentationRegistry.getArguments().getString("aniceRawFrames") == "true"
        val run = InstrumentationRegistry.getArguments().getString("aniceRawRun")
        assumeTrue("Isolated socket diagnostic requires aniceRawRun", run != null)
        require(UUID.fromString(run).toString() == run)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.filesDir, "raw-lan-$run").apply { mkdirs() }
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = requireNotNull(manager.allNetworks.firstOrNull {
            manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        })
        val address = requireNotNull(manager.getLinkProperties(network)?.linkAddresses?.firstOrNull {
            it.address is Inet4Address && !it.address.isLoopbackAddress
        }?.address)
        val server = java.net.ServerSocket(0, 1, address).apply { soTimeout = 60000 }
        @Suppress("DEPRECATION")
        val lock = context.applicationContext.getSystemService(android.net.wifi.WifiManager::class.java)
            .createWifiLock(android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF, "aniCe:raw LAN diagnostic")
        lock.setReferenceCounted(false)
        try {
            withTimeout(120000) {
                val state = android.app.ActivityManager.RunningAppProcessInfo()
                do {
                    android.app.ActivityManager.getMyMemoryState(state)
                    if (state.importance <= android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND) break
                    delay(250)
                } while (true)
            }
            lock.acquire()
            File(directory, "server.json").writeText(JSONObject().put("address", address.hostAddress)
                .put("port", server.localPort).toString())
            server.accept().use { socket ->
                socket.soTimeout = 10000
                socket.tcpNoDelay = true
                val total = 100 * 1048576
                val buffer = ByteArray(65536)
                val framing = if (framed) LanFraming(SessionProfile.BULK_PROBE) { SystemClock.elapsedRealtime() } else null
                val digest = java.security.MessageDigest.getInstance("SHA-256")
                var remaining = total
                val start = SystemClock.elapsedRealtimeNanos()
                while (remaining > 0) {
                    socket.soTimeout = framing?.nextDeadline?.let { (it - SystemClock.elapsedRealtime()).coerceIn(1, 10000).toInt() } ?: 10000
                    val count = socket.getInputStream().read(buffer, 0, if (framed) buffer.size else minOf(buffer.size, remaining))
                    require(count > 0)
                    if (framing == null) {
                        digest.update(buffer, 0, count)
                        remaining -= count
                    } else {
                        val at = framing.beginBuffer()
                        var offset = 0
                        while (offset < count) {
                            val frame = framing.feed(buffer, offset, count - offset, at)
                            offset += framing.consumed
                            if (frame != null) {
                                require(frame.size <= remaining)
                                digest.update(frame)
                                remaining -= frame.size
                            }
                        }
                    }
                }
                framing?.end()
                val receivedDigest = digest.digest().joinToString("") { "%02x".format(it) }
                val receiveSeconds = (SystemClock.elapsedRealtimeNanos() - start) / 1e9
                val outgoing = ByteArray(if (framed) 4194304 else buffer.size) { 42.toByte() }
                val sendStart = SystemClock.elapsedRealtimeNanos()
                repeat(total / outgoing.size) { socket.getOutputStream().write(if (framed) LanFraming.encode(outgoing, SessionProfile.BULK_PROBE) else outgoing) }
                socket.getOutputStream().flush()
                require(socket.getInputStream().read() == 1)
                val sendSeconds = (SystemClock.elapsedRealtimeNanos() - sendStart) / 1e9
                File(directory, "result.json").writeText(JSONObject().put("bytes", total).put("framed", framed)
                    .put("androidReceiveMiBs", 100 / receiveSeconds).put("androidSendMiBs", 100 / sendSeconds)
                    .put("receivedSha256", receivedDigest).toString())
            }
            withTimeout(30000) { while (!File(directory, "ack").exists()) delay(100) }
        } finally {
            if (lock.isHeld) lock.release()
            server.close()
            directory.deleteRecursively()
        }
    }

    @Test
    fun protectedTcpInterchange(): Unit = runBlocking {
        LanNativeBenchmark.selfCheck()
        val args = InstrumentationRegistry.getArguments()
        val run = args.getString("aniceLanRun")
        assumeTrue("Run through scripts/verify-lan-interchange.py", run != null)
        require(UUID.fromString(run).toString() == run)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.filesDir, "lan-interchange-$run").apply { mkdirs() }
        val namespace = "anice.test.lan.$run."
        val metadataName = "test-lan-$run.json"
        val keys = AndroidIdentityKeys()
        val identity =
            IdentityService(
                AndroidIdentityMetadata(context, metadataName),
                keys,
                { "LAN test" },
                namespace,
            )
        val before =
            context.noBackupFilesDir
                .listFiles()
                .orEmpty()
                .filter { it.isFile && !it.name.startsWith("test-") }
                .associate { it.name to SessionCrypto.hash(it.readBytes()).toList() }
        var engine: SessionConnection? = null
        var tcp: AndroidLanTransport? = null
        var receiver: Job? = null
        var wifiLock: android.net.wifi.WifiManager.WifiLock? = null
        try {
            val config = JSONObject(File(directory, "server.json").readText())
            val family = config.getString("family")
            require(family == "ipv4" || family == "link-local")
            val peer = DeviceIdentity.fromJson(config.getJSONObject("identity"))
            val local = identity.getOrCreateIdentity().identity
            val profileName = config.optString("profile", "standard")
            require(profileName in listOf("standard", "bulk-probe", "lan-transfer"))
            val profile = when (profileName) { "standard" -> SessionProfile.STANDARD; "lan-transfer" -> SessionProfile.LAN_TRANSFER; else -> SessionProfile.BULK_PROBE }
            val benchmarkMiB = config.optInt("benchmarkMiB", 0)
            if (benchmarkMiB != 0) {
                // Instrumentation restarts the target process; foreground acceptance needs a manual reopen.
                withTimeout(120000) {
                    val state = android.app.ActivityManager.RunningAppProcessInfo()
                    do {
                        android.app.ActivityManager.getMyMemoryState(state)
                        if (state.importance <= android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND) break
                        delay(250)
                    } while (true)
                }
                @Suppress("DEPRECATION")
                val lock = context.applicationContext.getSystemService(android.net.wifi.WifiManager::class.java)
                    .createWifiLock(android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF, "aniCe:LAN benchmark")
                lock.setReferenceCounted(false)
                lock.acquire()
                wifiLock = lock
                check(lock.isHeld)
            }
            val window = config.optInt("window", 32)
            require(benchmarkMiB in listOf(0, 4, 16, 100, 1024) && window in (if (profile == SessionProfile.STANDARD) listOf(32, 64) else listOf(4, 8)))
            val bulk = LanNativeBenchmark(benchmarkMiB * 1048576, window, if (profile == SessionProfile.STANDARD) 3072 else if (profile == SessionProfile.LAN_TRANSFER) 131072 else profile.maximumPlaintext - 5)
            File(directory, "client.json")
                .writeText(JSONObject().put("identity", local.toJson())
                    .put("benchmarkMiB", benchmarkMiB).put("window", window).put("profile", profileName).toString())
            // The Mac pins this public test credential before accepting EDHOC.
            withTimeout(30000) { while (!File(directory, "go").exists()) delay(50) }
            val manager = context.getSystemService(ConnectivityManager::class.java)
            val network =
                requireNotNull(
                    manager.allNetworks.firstOrNull {
                        manager
                            .getNetworkCapabilities(it)
                            ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                    }
                ) {
                    "A physical Wi-Fi network is required"
                }
            val socket = AndroidLanTransport(this, profile) { bulk.wake() }
            tcp = socket
            val endpoints =
                AndroidLanDiscovery(context, profile).discover(network) {
                    manager.getLinkProperties(network)
                }
            val endpoint =
                requireNotNull(
                    endpoints.firstOrNull {
                        it.port == config.getInt("port") &&
                            if (family == "ipv4") it.address is Inet4Address
                            else
                                it.address is Inet6Address &&
                                    it.address.isLinkLocalAddress &&
                                    it.address.scopeId > 0
                    }
                ) {
                    "Native Bonjour discovery did not resolve the isolated listener"
                }
            socket.connect(endpoint)
            val handshake =
                SessionHandshakeEngine(
                    local,
                    false,
                    { listOf(peer) },
                    { identity.getOrCreateIdentity().identity },
                    { input ->
                        identity.sign(input).let {
                            SessionProof(it.snapshot.identity, it.signature)
                        }
                    },
                    peer,
                )
            val ready = CompletableDeferred<Unit>()
            val received = CompletableDeferred<ByteArray>()
            val channel =
                SessionConnection(
                    handshake,
                    false,
                    socket::hasCapacity,
                    socket::submit,
                    { if (it.size == 4000) received.complete(it) else bulk.handle(it) },
                    { ready.complete(Unit) },
                    controls = true,
                    changed = { bulk.wake() },
                    profile = profile,
                )
            engine = channel
            receiver =
                launch(Dispatchers.IO) {
                    try {
                        socket.receive(channel::receive)
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Exception) {
                        ready.completeExceptionally(error)
                        received.completeExceptionally(error)
                        bulk.failed(error)
                    }
                }
            withTimeout(30000) {
                channel.start()
                ready.await()
            }
            withTimeout(5000) { while (channel.controlSupport != true) delay(50) }
            val payload = ByteArray(4000) { (it % 128).toByte() }
            channel.sendData(payload)
            assertArrayEquals(payload.reversedArray(), withTimeout(10000) { received.await() })
            assertEquals(local, identity.getOrCreateIdentity().identity)
            val metrics = if (benchmarkMiB != 0) {
                try { withTimeout(maxOf(60000L, benchmarkMiB * 500L)) { bulk.run(channel) } }
                catch (error: TimeoutCancellationException) {
                    File(directory, "benchmark-failure.json").writeText(bulk.progress().toString())
                    withTimeout(30000) { while (!File(directory, "ack").exists()) delay(50) }
                    throw AssertionError("Production DATA benchmark exceeded its completion budget", error)
                }
            } else null
            metrics?.let {
                val (send, receive) = socket.bufferSizes()
                it.put("socketSendBytes", send).put("socketReceiveBytes", receive)
                it.put("socketReadMs", socket.readNanos / 1_000_000)
                    .put("recordDeliveryMs", socket.deliveryNanos / 1_000_000)
            }
            channel.disconnect()
            File(directory, "result.json")
                .writeText(
                    JSONObject()
                        .put("tcp", true)
                        .put("controls", true)
                        .put("bidirectionalBytes", 4000)
                        .put("family", family)
                        .apply { if (metrics != null) put("benchmark", metrics) }
                        .toString()
                )
            withTimeout(30000) { while (!File(directory, "ack").exists()) delay(50) }
        } finally {
            wifiLock?.let { if (it.isHeld) it.release() }
            engine?.retire()
            tcp?.close()
            receiver?.cancelAndJoin()
            engine?.close()
            keys.aliases().filter { it.startsWith(namespace) }.forEach(keys::delete)
            AtomicFile(File(context.noBackupFilesDir, metadataName)).delete()
            assertTrue(keys.aliases().none { it.startsWith(namespace) })
            for ((name, digest) in before) assertEquals(
                "Production journal changed: $name",
                digest,
                SessionCrypto.hash(File(context.noBackupFilesDir, name).readBytes()).toList(),
            )
            directory.deleteRecursively()
        }
    }
}

// Bulk probes use the production socket, keys and record counters with bounded cumulative credit.
private class LanNativeBenchmark(val total: Int, val window: Int, val chunkBytes: Int = 3072) {
    companion object {
        fun selfCheck() {
            val positive = LanNativeBenchmark(3074, 32)
            positive.handle(byteArrayOf(0x42, 0, 0, 0, 0) + ByteArray(3072))
            positive.handle(byteArrayOf(0x42, 0, 0, 12, 0, 1, 1))
            assertEquals(3074, positive.snapshot().second)
            assertArrayEquals(byteArrayOf(0x41, 0, 0, 12, 2), positive.takeAck())
            positive.admitted = 3074
            positive.handle(byteArrayOf(0x41, 0, 0, 12, 2))
            assertEquals(3074, positive.snapshot().third)
            val invalid = listOf(
                byteArrayOf(), byteArrayOf(0x42, 0, 0),
                byteArrayOf(0x42, 0, 0, 0, 1, 0, 0),
                byteArrayOf(0x42, 0, 0, 0, 0, 1, 1),
                byteArrayOf(0x42, 0, 0, 0, 0, 0),
                byteArrayOf(0x41, 0, 0, 0, 2),
            )
            assertTrue(invalid.size >= 6)
            for (bytes in invalid) {
                try { LanNativeBenchmark(2, 32).handle(bytes); fail("Malformed benchmark record accepted") }
                catch (_: IllegalArgumentException) {}
            }
            try { positive.handle(byteArrayOf(0x41, 0, 0, 12, 2)); fail("Duplicate ACK accepted") }
            catch (_: IllegalArgumentException) {}
        }
    }
    private val lock = Any()
    private val writer = Mutex()
    private val revision = MutableStateFlow(0L)
    private var received = 0
    private var acknowledged = 0
    private var admitted = 0
    private var pendingAck: Int? = null
    private var submittedAck = 0
    private var failure: Exception? = null
    private var startedNanos = 0L
    private var cpuStart = 0L
    fun progress(): JSONObject = synchronized(lock) {
        JSONObject().put("bytes", total).put("window", window).put("completed", false)
            .put("throughputPassed", false).put("reason", "completion-deadline")
            .put("androidReceivedBytes", received).put("androidAcknowledgedBytes", acknowledged)
            .put("elapsedSeconds", (SystemClock.elapsedRealtimeNanos() - startedNanos) / 1e9)
            .put("androidCpuMs", android.os.Process.getElapsedCpuTime() - cpuStart)
    }
    fun wake() = synchronized(lock) { revision.value++ }
    fun failed(error: Exception) = synchronized(lock) { failure = error; wake() }
    private fun snapshot(): Triple<Long, Int, Int> = synchronized(lock) {
        failure?.let { throw it }
        Triple(revision.value, received, acknowledged)
    }
    private suspend fun wait(version: Long) { revision.first { it != version } }
    fun handle(bytes: ByteArray) = synchronized(lock) {
        require(bytes.size >= 5)
        val index = ByteBuffer.wrap(bytes, 1, 4).int
        when (bytes[0].toInt()) {
            0x42 -> {
                require(index == received && received < total && bytes.size == 5 + minOf(chunkBytes, total - received))
                val expectedByte = ((index / chunkBytes) % 251).toByte()
                var valid = true
                for (position in 5 until bytes.size) {
                    if (bytes[position] != expectedByte) { valid = false; break }
                }
                require(valid)
                received += bytes.size - 5
                if (received == total || (received / chunkBytes) % minOf(16, window / 2) == 0) pendingAck = received
            }
            0x41 -> {
                require(bytes.size == 5 && index > acknowledged && index <= admitted && (index == total || index % chunkBytes == 0))
                acknowledged = index
            }
            else -> error("Unknown benchmark record")
        }
        wake()
    }
    private fun takeAck(): ByteArray? = synchronized(lock) {
        pendingAck?.let { pendingAck = null; ByteBuffer.allocate(5).put(0x41).putInt(it).array() }
    }
    private suspend fun send(channel: SessionConnection, bytes: ByteArray) = writer.withLock {
        while (true) {
            val version = snapshot().first
            if (!channel.applicationAvailable) { wait(version); continue }
            try { channel.sendData(bytes); break }
            catch (_: SessionBackpressure) { wait(version) }
        }
    }
    suspend fun run(channel: SessionConnection): JSONObject = coroutineScope {
        val replies = launch(Dispatchers.IO) {
            try {
                while (isActive) {
                    val version = snapshot().first
                    val ack = takeAck()
                    if (ack != null) {
                        send(channel, ack)
                        synchronized(lock) { submittedAck = ByteBuffer.wrap(ack, 1, 4).int; wake() }
                    } else wait(version)
                }
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) { failed(error) }
        }
        try {
            cpuStart = android.os.Process.getElapsedCpuTime()
            startedNanos = SystemClock.elapsedRealtimeNanos()
            val gcStart = android.os.Debug.getRuntimeStats()
            val processState = android.app.ActivityManager.RunningAppProcessInfo()
            android.app.ActivityManager.getMyMemoryState(processState)
            val importanceAtStart = processState.importance
            val sendStart = SystemClock.elapsedRealtimeNanos()
            var sent = 0
            val chunk = ByteArray(chunkBytes + 5)
            while (sent < total) {
                val (version, _, ack) = snapshot()
                if (sent - ack >= window * chunkBytes) { wait(version); continue }
                val count = minOf(chunkBytes, total - sent)
                ByteBuffer.wrap(chunk).put(0x42).putInt(sent)
                java.util.Arrays.fill(chunk, 5, 5 + count, ((sent / chunkBytes) % 251).toByte())
                synchronized(lock) { admitted = sent + count }
                send(channel, if (count == chunkBytes) chunk else chunk.copyOf(5 + count))
                sent += count
            }
            while (true) {
                val (version, _, ack) = snapshot()
                if (ack == total) break
                wait(version)
            }
            val sendSeconds = (SystemClock.elapsedRealtimeNanos() - sendStart) / 1e9
            val receiveStart = SystemClock.elapsedRealtimeNanos()
            while (true) {
                val (version, count, _) = snapshot()
                if (count == total) break
                wait(version)
            }
            // The final ACK must finish submission before the terminal disconnect record.
            while (true) {
                val version = snapshot().first
                if (synchronized(lock) { submittedAck == total }) break
                wait(version)
            }
            replies.cancelAndJoin()
            val receiveSeconds = (SystemClock.elapsedRealtimeNanos() - receiveStart) / 1e9
            android.app.ActivityManager.getMyMemoryState(processState)
            JSONObject().put("bytes", total).put("window", window)
                .put("processImportanceAtStart", importanceAtStart)
                .put("processImportanceAtEnd", processState.importance)
                .put("androidCpuMs", android.os.Process.getElapsedCpuTime() - cpuStart)
                .apply {
                    for (key in listOf("art.gc.gc-count", "art.gc.gc-time", "art.gc.bytes-allocated")) {
                        val first = gcStart[key]?.toLongOrNull()
                        val last = android.os.Debug.getRuntimeStat(key)?.toLongOrNull()
                        if (first != null && last != null) put(key, last - first)
                    }
                }
                .put("androidSendMiBs", total / 1048576.0 / sendSeconds)
                .put("androidReceiveMiBs", total / 1048576.0 / receiveSeconds)
        } finally { replies.cancelAndJoin() }
    }
}
