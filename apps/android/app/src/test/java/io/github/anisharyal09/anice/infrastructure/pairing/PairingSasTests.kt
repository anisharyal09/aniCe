// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies independent SAS vectors, consent-gated identity openings and durable trust receipts.
package io.github.anisharyal09.anice.infrastructure.pairing

import io.github.anisharyal09.anice.infrastructure.identity.*
import java.security.*
import java.security.spec.ECGenParameterSpec
import javax.crypto.KeyAgreement
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PairingSasTests {
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun independentVectorsAndUniformLeadingZeros() {
        val resource = checkNotNull(javaClass.classLoader?.getResourceAsStream("sas-vectors.json"))
        val root = JSONObject(resource.bufferedReader().use { it.readText() })
        assertEquals(1, root.getInt("fixtureVersion"))
        val vectors = root.getJSONArray("valid")
        assertEquals(2, vectors.length())
        repeat(vectors.length()) { index ->
            val v = vectors.getJSONObject(index)
            fun bytes(name: String) = hex(v.getString(name + "Hex"))
            for ((name, platform) in listOf("clientIdentity" to "android", "serverIdentity" to "macos")) {
                val identity = DeviceIdentity.fromJson(JSONObject(String(bytes(name), Charsets.UTF_8)))
                assertEquals(platform, identity.platform)
            }
            val clientIC = PairingSas.identityCommitment(1, bytes("clientIdentitySalt"), bytes("clientIdentity"))
            val serverIC = PairingSas.identityCommitment(2, bytes("serverIdentitySalt"), bytes("serverIdentity"))
            assertArrayEquals(bytes("clientIdentityCommitment"), clientIC)
            assertArrayEquals(bytes("serverIdentityCommitment"), serverIC)
            val transcript = PairingSas.transcript(bytes("rendezvous"), bytes("serverNonce"),
                bytes("clientCommitment"), bytes("serverCommitment"), bytes("clientPublic"),
                bytes("serverPublic"), bytes("clientNonce"), bytes("serverComparisonNonce"), clientIC, serverIC)
            assertArrayEquals(bytes("transcript"), transcript)
            val key = PairingSas.bootstrap(bytes("sharedSecret"), transcript)
            assertArrayEquals(bytes("bootstrapKey"), key)
            val digits = PairingSas.digits(key, transcript)
            assertEquals(v.getString("digits"), digits)
            if (v.getString("name") == "leading-zero") assertTrue(digits.startsWith("0"))
            assertArrayEquals(bytes("clientFinish"), PairingCodec.mac(
                PairingCodec.derive(key, "client-auth", PairingCodec.hash(transcript)), transcript))
            val channel = PairingChannel(key, transcript, false)
            assertArrayEquals(bytes("serverFinish"), channel.confirm())
            assertArrayEquals(bytes("encryptedComparison"), channel.seal(PairingCodec.message(15)))
            val alteredNonce = bytes("clientNonce").also { it[0] = (it[0].toInt() xor 1).toByte() }
            assertThrows(IllegalArgumentException::class.java) {
                PairingSas.transcript(bytes("rendezvous"), bytes("serverNonce"),
                    bytes("clientCommitment"), bytes("serverCommitment"), bytes("clientPublic"),
                    bytes("serverPublic"), alteredNonce, bytes("serverComparisonNonce"), clientIC, serverIC)
            }
            val changedIdentity = bytes("clientIdentity").also { it[it.lastIndex] = 0 }
            assertFalse(PairingSas.identityCommitment(1, bytes("clientIdentitySalt"), changedIdentity).contentEquals(clientIC))
        }
        val decimals = root.getJSONArray("decimal")
        repeat(decimals.length()) { index ->
            val item = decimals.getJSONObject(index)
            assertEquals(if (item.isNull("digits")) null else item.getString("digits"),
                PairingSas.decimal(hex(item.getString("hex"))))
        }
        assertThrows(IllegalArgumentException::class.java) { PairingSas.decimal(ByteArray(3)) }
    }

    private class Memory : TrustPersistence {
        var data: ByteArray? = null
        var fail = false
        override fun read() = data
        override fun write(bytes: ByteArray) { check(!fail); data = bytes.clone() }
    }
    private class Metadata : IdentityMetadataStore {
        var value: IdentityJournal? = null
        override fun read() = value
        override fun write(journal: IdentityJournal) { value = journal }
    }
    private class Keys : IdentityKeyStore {
        val values = mutableMapOf<String, KeyPair>()
        var signatures = 0
        override fun aliases() = values.keys.toSet()
        override fun create(alias: String) { values[alias] = key() }
        override fun publicKey(alias: String) = values[alias]?.let { IdentityCrypto.exportPublicKey(it.public) }
        override fun protection(alias: String) = KeyProtection.PLATFORM
        override fun sign(alias: String, message: ByteArray): ByteArray {
            signatures++
            return sign(values.getValue(alias), message)
        }
        override fun delete(alias: String) { values.remove(alias) }
    }
    private class Rig {
        val keys = Keys()
        val identity = IdentityService(Metadata(), keys, { "Synthetic Android" })
        val local = identity.getOrCreateIdentity().identity
        val memory = Memory()
        val trust = PeerTrustStore(memory)
        val output = mutableListOf<ByteArray>()
        val events = mutableListOf<String>()
        var digits: String? = null
        var current = true
        val engine = PairingEngine(PairingMethod.SAS, null, byteArrayOf(), identity, trust,
            { output.add(it) }, { state, _ -> events.add(state) }, { digits = it }, { current })
        val signing = key()
        val publicIdentity = IdentityCrypto.exportPublicKey(signing.public)
        val mac = DeviceIdentity(DeviceIdentity.newId(), "Synthetic Mac", "macos",
            IdentityCrypto.encodeBase64(publicIdentity), IdentityCrypto.fingerprint(publicIdentity)).validate()
        val macBytes = mac.toJson().toString().toByteArray()
        val serverKey = key()
        val rendezvous = ByteArray(16) { it.toByte() }
        val serverNonce = ByteArray(32) { it.toByte() }
        val salt = ByteArray(32) { 7 }
        val nonce = ByteArray(32) { 8 }
        lateinit var channel: PairingChannel
        lateinit var transcript: ByteArray
        lateinit var clientIC: ByteArray

        fun bootstrap() {
            engine.receive(PairingCodec.message(2, byteArrayOf(3), rendezvous, serverNonce))
            val hello = PairingCodec.unpack(output.removeAt(0), 3, 3)
            assertNull(digits)
            val sp = IdentityCrypto.exportPublicKey(serverKey.public)
            val serverIC = PairingSas.identityCommitment(2, salt, macBytes)
            val commitment = PairingSas.commitment(2, rendezvous, serverNonce, sp, nonce, serverIC)
            engine.receive(PairingCodec.message(4, serverNonce, commitment))
            val reveal = PairingCodec.unpack(output.removeAt(0), 8, 3)
            clientIC = reveal[2]
            transcript = PairingSas.transcript(rendezvous, serverNonce, hello[2], commitment,
                reveal[0], sp, reveal[1], nonce, clientIC, serverIC)
            val secret = KeyAgreement.getInstance("ECDH").run {
                init(serverKey.private); doPhase(IdentityCrypto.publicKey(reveal[0]), true); generateSecret()
            }
            val key = PairingSas.bootstrap(secret, transcript)
            secret.fill(0)
            channel = PairingChannel(key, transcript, true)
            engine.receive(PairingCodec.message(9, sp, nonce, serverIC))
            assertNull(digits)
            val finish = PairingCodec.unpack(output.removeAt(0), 5, 1)[0]
            assertArrayEquals(PairingCodec.mac(PairingCodec.derive(key, "client-auth",
                PairingCodec.hash(transcript)), transcript), finish)
            engine.receive(PairingCodec.message(6, channel.confirm()))
            assertEquals(PairingSas.digits(key, transcript), digits)
            assertTrue(output.isEmpty())
            assertTrue(trust.list(local.fingerprint).isEmpty())
            assertEquals(1, keys.signatures)
        }
        fun disclose(): ByteArray {
            engine.confirmComparison()
            assertEquals(1, output.size)
            assertArrayEquals(PairingCodec.message(15), channel.open(output.removeAt(0)))
            assertTrue(output.isEmpty())
            engine.receive(channel.seal(PairingCodec.message(15)))
            val fields = PairingCodec.unpack(channel.open(output.removeAt(0)), 10, 2)
            assertArrayEquals(clientIC, PairingSas.identityCommitment(1, fields[1], fields[0]))
            return fields[0]
        }
    }

    @Test fun bothConfirmThenVerifyIdentityAndDurableReceipts() {
        val r = Rig(); r.bootstrap()
        val clientBytes = r.disclose()
        val hash = PairingCodec.hash(r.transcript)
        r.engine.receive(r.channel.seal(PairingCodec.message(10, r.macBytes, r.salt)))
        val proof = PairingCodec.unpack(r.channel.open(r.output.removeAt(0)), 11, 1)[0]
        assertTrue(IdentityCrypto.verify(IdentityCrypto.decodeBase64(r.local.publicKey),
            PairingCodec.proof(hash, clientBytes, r.macBytes, 1), proof))
        r.engine.receive(r.channel.seal(PairingCodec.message(11,
            sign(r.signing, PairingCodec.proof(hash, clientBytes, r.macBytes, 2)))))
        assertArrayEquals(PairingCodec.message(12), r.channel.open(r.output.removeAt(0)))
        assertTrue(r.trust.list(r.local.fingerprint).isEmpty())
        r.engine.receive(r.channel.seal(PairingCodec.message(12)))
        val receipt = PairingCodec.unpack(r.channel.open(r.output.removeAt(0)), 13, 1)[0]
        val trustHash = PairingCodec.hash(PairingCodec.proof(hash, clientBytes, r.macBytes))
        assertTrue(IdentityCrypto.verify(IdentityCrypto.decodeBase64(r.local.publicKey),
            PairingCodec.receipt(trustHash, 1), receipt))
        assertTrue(r.trust.list(r.local.fingerprint).isEmpty())
        r.engine.receive(r.channel.seal(PairingCodec.message(13,
            sign(r.signing, PairingCodec.receipt(trustHash, 2)))))
        assertEquals(PairingMethod.SAS, r.trust.list(r.local.fingerprint).single().method)
        assertTrue(r.events.contains("paired"))
        r.engine.close()
        assertEquals(r.mac, PeerTrustStore(r.memory).list(r.local.fingerprint).single().peer)
    }

    @Test fun earlyIdentityProofApprovalAndReceiptRetireTheComparison() {
        for (type in listOf(10, 11, 12, 13)) {
            val r = Rig(); r.bootstrap()
            val bytes = when (type) {
                10 -> PairingCodec.message(10, r.macBytes, r.salt)
                12 -> PairingCodec.message(12)
                else -> PairingCodec.message(type, byteArrayOf(1))
            }
            assertThrows(Exception::class.java) { r.engine.receive(r.channel.seal(bytes)) }
            assertThrows(Exception::class.java) { r.engine.confirmComparison() }
            assertTrue(r.trust.list(r.local.fingerprint).isEmpty())
        }
    }

    @Test fun identityOpeningMustMatchAfterBothConfirm() {
        val r = Rig(); r.bootstrap(); r.disclose()
        val salt = r.salt.clone().also { it[0] = 99 }
        assertThrows(Exception::class.java) { r.engine.receive(r.channel.seal(PairingCodec.message(10, r.macBytes, salt))) }
        assertTrue(r.trust.list(r.local.fingerprint).isEmpty())
        assertThrows(Exception::class.java) { r.engine.confirmComparison() }
    }

    @Test fun dismissSendsCancelAndDropsSecretsWithoutTrust() {
        val r = Rig(); r.bootstrap()
        r.engine.decline()
        assertArrayEquals(PairingCodec.message(14), r.channel.open(r.output.single()))
        assertThrows(Exception::class.java) { r.engine.confirmComparison() }
        assertTrue(PeerTrustStore(r.memory).list(r.local.fingerprint).isEmpty())
    }

    @Test fun renamedIdentityCannotConfirmOrBeDisclosed() {
        val r = Rig(); r.bootstrap()
        r.identity.rename("Changed Android")
        assertThrows(Exception::class.java) { r.engine.confirmComparison() }
        assertTrue(r.output.isEmpty())
        r.engine.close()
    }

    @Test fun invalidOrderingCannotDisplayDigits() {
        for (message in listOf(PairingCodec.message(8, ByteArray(65), ByteArray(32), ByteArray(32)),
            PairingCodec.message(6, ByteArray(32)), PairingCodec.message(2, byteArrayOf(1), ByteArray(16), ByteArray(32)))) {
            val r = Rig()
            assertThrows(Exception::class.java) { r.engine.receive(message) }
            assertNull(r.digits)
            assertThrows(Exception::class.java) { r.engine.confirmComparison() }
        }
    }

    @Test fun reflectionAndMalformedPointsAreRejected() {
        val r = Rig()
        r.engine.receive(PairingCodec.message(2, byteArrayOf(3), r.rendezvous, r.serverNonce))
        val hello = PairingCodec.unpack(r.output.removeAt(0), 3, 3)
        r.engine.receive(PairingCodec.message(4, r.serverNonce, ByteArray(32)))
        val reveal = PairingCodec.unpack(r.output.removeAt(0), 8, 3)
        assertThrows(Exception::class.java) {
            r.engine.receive(PairingCodec.message(9, reveal[0], r.nonce, hello[2]))
        }
        assertNull(r.digits)
        assertThrows(IllegalArgumentException::class.java) {
            PairingSas.commitment(2, r.rendezvous, r.serverNonce, ByteArray(65), r.nonce, ByteArray(32))
        }
    }

    @Test fun revocationDuringSavingNeverWritesTrustOrSendsReceipt() {
        val r = Rig(); r.bootstrap()
        val clientBytes = r.disclose()
        val hash = PairingCodec.hash(r.transcript)
        r.engine.receive(r.channel.seal(PairingCodec.message(10, r.macBytes, r.salt)))
        r.output.clear()
        r.engine.receive(r.channel.seal(PairingCodec.message(11,
            sign(r.signing, PairingCodec.proof(hash, clientBytes, r.macBytes, 2)))))
        r.output.clear()
        r.current = false
        assertThrows(Exception::class.java) { r.engine.receive(r.channel.seal(PairingCodec.message(12))) }
        assertTrue(r.output.isEmpty())
        assertTrue(PeerTrustStore(r.memory).list(r.local.fingerprint).isEmpty())
    }

    @Test fun persistenceFailureNeverCompletesPairing() {
        val r = Rig(); r.bootstrap()
        val clientBytes = r.disclose()
        val hash = PairingCodec.hash(r.transcript)
        r.engine.receive(r.channel.seal(PairingCodec.message(10, r.macBytes, r.salt)))
        r.output.clear()
        r.engine.receive(r.channel.seal(PairingCodec.message(11,
            sign(r.signing, PairingCodec.proof(hash, clientBytes, r.macBytes, 2)))))
        r.output.clear()
        r.memory.fail = true
        assertThrows(Exception::class.java) { r.engine.receive(r.channel.seal(PairingCodec.message(12))) }
        assertTrue(r.output.isEmpty())
        assertFalse(r.events.contains("paired"))
        r.memory.fail = false
        assertTrue(PeerTrustStore(r.memory).list(r.local.fingerprint).isEmpty())
    }

    @Test fun synchronousRevocationBlocksQueuedComparison() {
        val r = Rig(); r.bootstrap(); r.current = false
        assertThrows(Exception::class.java) { r.engine.confirmComparison() }
        assertThrows(Exception::class.java) { r.engine.receive(r.channel.seal(PairingCodec.message(15))) }
        assertTrue(r.output.isEmpty())
        assertTrue(r.trust.list(r.local.fingerprint).isEmpty())
    }

    companion object {
        private fun key(): KeyPair = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec("secp256r1")); generateKeyPair()
        }
        private fun sign(key: KeyPair, bytes: ByteArray): ByteArray =
            Signature.getInstance("SHA256withECDSA").run {
                initSign(key.private); update(bytes); sign()
            }
    }
}
