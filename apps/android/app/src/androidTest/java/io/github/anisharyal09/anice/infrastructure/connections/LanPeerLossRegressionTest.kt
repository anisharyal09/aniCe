// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises peer-loss verification against fresh in-memory EDHOC sessions, never user keys or native connection attempts.
package io.github.anisharyal09.anice.infrastructure.connections

import android.content.Context
import androidx.compose.runtime.MutableState
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.identity.IdentityCrypto
import io.github.anisharyal09.anice.infrastructure.session.*
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanPeerLossRegressionTest {
    private class MemoryPair(val now: AtomicLong) {
        private val clientKey = key()
        private val serverKey = key()
        val clientPeer = identity(clientKey, "android")
        val serverPeer = identity(serverKey, "macos")
        val outgoing = ConcurrentLinkedQueue<ByteArray>()
        val replies = ConcurrentLinkedQueue<ByteArray>()
        var received: suspend () -> Unit = {}
        val client = SessionConnection(handshake(clientPeer, serverPeer, clientKey, false), false,
            { true }, { outgoing.add(it) }, { received() }, {}, now = now::get)
        val server = SessionConnection(handshake(serverPeer, clientPeer, serverKey, true), true,
            { true }, { replies.add(it) }, {}, {}, now = now::get)

        private fun handshake(local: DeviceIdentity, peer: DeviceIdentity, key: KeyPair, responder: Boolean) =
            SessionHandshakeEngine(local, responder, { listOf(peer) }, { local }, { bytes ->
                val signer = Signature.getInstance("SHA256withECDSA")
                signer.initSign(key.private); signer.update(bytes)
                SessionProof(local, signer.sign())
            }, peer, now = now::get)

        suspend fun secure() {
            client.start()
            repeat(16) {
                outgoing.poll()?.let { server.receive(it) }
                replies.poll()?.let { client.receive(it) }
            }
            assertTrue(client.applicationAvailable)
            assertTrue(server.applicationAvailable)
            assertTrue(outgoing.isEmpty())
        }

        suspend fun close() { client.close(); server.close() }

        companion object {
            private fun key(): KeyPair = KeyPairGenerator.getInstance("EC")
                .apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
            private fun identity(key: KeyPair, platform: String): DeviceIdentity {
                val bytes = IdentityCrypto.exportPublicKey(key.public)
                return DeviceIdentity(UUID.randomUUID().toString(), "Isolated peer", platform,
                    IdentityCrypto.encodeBase64(bytes), IdentityCrypto.fingerprint(bytes)).validate()
            }
        }
    }

    private class Fixture(val app: AniCeApplication, val now: AtomicLong) {
        val name = "lan-peer-loss-regression.${UUID.randomUUID()}"
        val preferences = app.getSharedPreferences(name, Context.MODE_PRIVATE).also {
            check(it.edit().putBoolean("automatic_lan", false).commit())
        }
        val presentation = Any()
        val controller = LanSessionController(app, backgroundTimeoutMillis = { 0 },
            recoveryDelays = emptyList(), elapsedRealtime = now::get, interactive = { true },
            preferences = preferences)

        fun field(name: String): Any? = LanSessionController::class.java.getDeclaredField(name)
            .apply { isAccessible = true }.get(controller)
        val generation get() = field("generation") as Long

        @Suppress("UNCHECKED_CAST")
        fun bind(pair: MemoryPair) {
            LanSessionController::class.java.getDeclaredField("connection").apply { isAccessible = true }
                .set(controller, pair.client)
            (field("selected\$delegate") as MutableState<DeviceIdentity?>).value = pair.serverPeer
            (field("connectionState\$delegate") as MutableState<ConnectionState>).value = ConnectionState.SECURED
            val op = generation
            pair.received = { withContext(Dispatchers.Main) { controller.authenticatedLanActivity(op) } }
        }

        fun channel(peer: DeviceIdentity, instance: String = "current-ble") = object : SecuredChannel {
            override val descriptor = ChannelDescriptor(instance, "ble", peer)
            override suspend fun sendData(bytes: ByteArray) {}
        }
        suspend fun suspect(channel: SecuredChannel) {
            controller.rendezvous.available(channel)
            controller.rendezvous.handle(channel.descriptor, LanRendezvousWire.encode(LanRendezvousMessage(2, 3)))
            controller.rendezvous.handle(channel.descriptor, LanRendezvousWire.encode(LanRendezvousMessage(2, 0)))
        }
        fun close() { controller.dispose(); app.deleteSharedPreferences(name) }
    }

    private suspend fun fixture(now: AtomicLong): Fixture = withContext(Dispatchers.Main) {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
        assumeTrue("Requires the disposable native-regression app",
            app.packageName == "io.github.anisharyal09.anice.preview.transfer.regression")
        Fixture(app, now).also { it.controller.foreground(it.presentation) }
    }

    @Test fun failedPeerStateVerificationRetiresOnlyLanAtTheAbsoluteDeadline() = runBlocking {
        val now = AtomicLong(100)
        val pair = MemoryPair(now).also { it.secure() }
        val fixture = fixture(now)
        try {
            withContext(Dispatchers.Main) {
                fixture.bind(pair)
                val channel = fixture.channel(pair.serverPeer)
                fixture.suspect(channel)
                assertTrue(fixture.controller.verifyingConnection)
                assertEquals(10_100L, fixture.field("checkDeadline"))
                repeat(20) { fixture.controller.rendezvous.handle(channel.descriptor,
                    LanRendezvousWire.encode(LanRendezvousMessage(2, 0))) }
                assertEquals(10_100L, fixture.field("checkDeadline"))
            }
            withTimeout(2_000) { while (pair.outgoing.isEmpty()) delay(10) }
            now.set(10_100)
            withContext(Dispatchers.Main) {
                fixture.controller.foreground(fixture.presentation)
                assertEquals(ConnectionState.DISCONNECTED, fixture.controller.state)
                assertFalse(fixture.controller.verifyingConnection)
            }
        } finally {
            withContext(NonCancellable + Dispatchers.Main) { fixture.close() }
            pair.close()
        }
    }

    @Test fun healthyLanReplySurvivesAnEligibilityOnlyWithdrawal() = runBlocking {
        val now = AtomicLong(100)
        val pair = MemoryPair(now).also { it.secure() }
        val fixture = fixture(now)
        try {
            withContext(Dispatchers.Main) {
                fixture.bind(pair)
                fixture.suspect(fixture.channel(pair.serverPeer))
                assertTrue(fixture.controller.verifyingConnection)
            }
            withTimeout(2_000) { while (pair.outgoing.isEmpty()) delay(10) }
            pair.server.receive(requireNotNull(pair.outgoing.poll()))
            pair.server.sendData(SessionController.CHECK_REPLY)
            pair.client.receive(requireNotNull(pair.replies.poll()))
            withContext(Dispatchers.Main) {
                assertFalse(fixture.controller.verifyingConnection)
                assertEquals(ConnectionState.SECURED, fixture.controller.state)
                now.set(10_200)
                fixture.controller.foreground(fixture.presentation)
                assertEquals(ConnectionState.SECURED, fixture.controller.state)
            }
        } finally {
            withContext(NonCancellable + Dispatchers.Main) { fixture.close() }
            pair.close()
        }
    }

    @Test fun oldVerificationAndAnotherCredentialCannotRetireTheReplacementLan() = runBlocking {
        val now = AtomicLong(100)
        val old = MemoryPair(now).also { it.secure() }
        val replacement = MemoryPair(now).also { it.secure() }
        val fixture = fixture(now)
        try {
            withContext(Dispatchers.Main) {
                fixture.bind(old)
                fixture.suspect(fixture.channel(old.serverPeer))
                val oldGeneration = fixture.generation
                fixture.controller.cancel()
                fixture.bind(replacement)
                now.set(10_200)
                val timeout = LanSessionController::class.java.getDeclaredMethod(
                    "checkExpired", java.lang.Long.TYPE, SessionConnection::class.java).apply { isAccessible = true }
                timeout.invoke(fixture.controller, oldGeneration, old.client)
                assertEquals(ConnectionState.SECURED, fixture.controller.state)
                assertSame(replacement.client, fixture.field("connection"))
                // Same ID/fingerprint is insufficient: the full public key must also match.
                fixture.suspect(fixture.channel(replacement.serverPeer.copy(publicKey = old.serverPeer.publicKey), "other"))
                assertFalse(fixture.controller.verifyingConnection)
                assertEquals(ConnectionState.SECURED, fixture.controller.state)
            }
        } finally {
            withContext(NonCancellable + Dispatchers.Main) { fixture.close() }
            old.close(); replacement.close()
        }
    }
}
