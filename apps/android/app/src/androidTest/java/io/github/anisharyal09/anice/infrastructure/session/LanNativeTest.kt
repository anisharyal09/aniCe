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
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanNativeTest {
    @Test
    fun protectedTcpInterchange(): Unit = runBlocking {
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
        try {
            val config = JSONObject(File(directory, "server.json").readText())
            val family = config.getString("family")
            require(family == "ipv4" || family == "link-local")
            val peer = DeviceIdentity.fromJson(config.getJSONObject("identity"))
            val local = identity.getOrCreateIdentity().identity
            File(directory, "client.json")
                .writeText(JSONObject().put("identity", local.toJson()).toString())
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
            val socket = AndroidLanTransport(this)
            tcp = socket
            val endpoints =
                AndroidLanDiscovery(context).discover(network) {
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
                    { received.complete(it) },
                    { ready.complete(Unit) },
                    controls = true,
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
            channel.disconnect()
            File(directory, "result.json")
                .writeText(
                    JSONObject()
                        .put("tcp", true)
                        .put("controls", true)
                        .put("bidirectionalBytes", 4000)
                        .put("family", family)
                        .toString()
                )
            withTimeout(30000) { while (!File(directory, "ack").exists()) delay(50) }
        } finally {
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
