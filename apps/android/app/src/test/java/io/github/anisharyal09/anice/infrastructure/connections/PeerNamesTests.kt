// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies display metadata ordering and private aliases without opening transport or modifying trust.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.identity.*
import io.github.anisharyal09.anice.infrastructure.pairing.*
import io.github.anisharyal09.anice.infrastructure.session.*
import java.security.*
import java.security.spec.ECGenParameterSpec
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class PeerNamesTests {
    private class Keys : IdentityKeyStore {
        val keys = mutableMapOf<String, KeyPair>()
        override fun aliases() = keys.keys.toSet()
        override fun create(alias: String) { keys[alias] = key() }
        override fun publicKey(alias: String) = keys[alias]?.let { IdentityCrypto.exportPublicKey(it.public) }
        override fun protection(alias: String) = KeyProtection.PLATFORM
        override fun sign(alias: String, message: ByteArray) = sign(keys.getValue(alias), message)
        override fun delete(alias: String) { keys.remove(alias) }
    }
    private class Metadata : IdentityMetadataStore {
        var row: IdentityJournal? = null
        override fun read() = row
        override fun write(journal: IdentityJournal) { row = journal }
    }
    private class TrustMemory : TrustPersistence {
        var bytes: ByteArray? = null
        override fun read() = bytes
        override fun write(bytes: ByteArray) { this.bytes = bytes.clone() }
    }
    private class Rig {
        val identity = IdentityService(Metadata(), Keys(), { "Android" })
        val local = identity.getOrCreateIdentity().identity
        val peerKey = key()
        val point = IdentityCrypto.exportPublicKey(peerKey.public)
        val peer = DeviceIdentity(DeviceIdentity.newId(), "Original Mac", "macos",
            IdentityCrypto.encodeBase64(point), IdentityCrypto.fingerprint(point))
        val trust = PeerTrustStore(TrustMemory())
        var saved: ByteArray? = null
        var failing = false
        init {
            val hash = ByteArray(32) { 9 }
            trust.prepare(PeerTrustRecord(peer, local.fingerprint, PairingMethod.QR, 1, hash))
            trust.activate(peer.deviceId, hash, sign(peerKey, PairingCodec.receipt(hash, 2)))
        }
        fun owner() = PeerNames(identity, { trust }, { saved?.clone() }, {
            check(!failing)
            saved = it.clone()
        }, Dispatchers.Unconfined, Dispatchers.Unconfined)
        fun link(transport: String) = Link(ChannelDescriptor(transport + "-instance", transport, peer))
    }
    private class Link(override val descriptor: ChannelDescriptor) : SecuredChannel {
        val sent = mutableListOf<ByteArray>()
        override suspend fun sendData(bytes: ByteArray) { sent.add(bytes) }
    }
    @Test fun wireBoundsAndUnknownTags() {
        assertEquals("8472616e69436520646576696365206e616d657301018101",
            NameWire.encode().joinToString("") { "%02x".format(it.toInt() and 255) })
        assertEquals(true to null, NameWire.decode(NameWire.encode()))
        for (name in listOf("Mac", "😀".repeat(64))) {
            val report = NameReport(Long.MAX_VALUE, name)
            assertEquals(false to report, NameWire.decode(NameWire.encode(report)))
        }
        assertThrows(Exception::class.java) { NameWire.encode(NameReport(-1, "Mac")) }
        assertThrows(Exception::class.java) { NameWire.encode(NameReport(1, " Mac ")) }
        assertThrows(Exception::class.java) { NameWire.encode(NameReport(1, "😀".repeat(65))) }
        assertNull(NameWire.decode(SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("other"))))))
    }
    @Test fun capabilityGatesReportsAndOrderingAcrossTransports() = runBlocking {
        val r = Rig(); val owner = r.owner()
        try {
            val ble = r.link("ble"); owner.available(ble)
            assertEquals(DataHandling.DISCARDED, owner.handle(ble.descriptor, NameWire.encode(NameReport(1, "Too early"))))
            owner.handle(ble.descriptor, NameWire.encode())
            assertEquals(DataHandling.HANDLED, owner.handle(ble.descriptor, NameWire.encode(NameReport(2, "New Mac"))))
            val lan = r.link("lan"); owner.available(lan); owner.handle(lan.descriptor, NameWire.encode())
            assertEquals(DataHandling.DISCARDED, owner.handle(lan.descriptor, NameWire.encode(NameReport(1, "Stale"))))
            assertEquals(DataHandling.DISCARDED, owner.handle(lan.descriptor, NameWire.encode(NameReport(2, "Conflict"))))
            assertEquals("New Mac", owner.deviceName(r.peer))
            owner.retired(ble.descriptor)
            assertEquals(DataHandling.DISCARDED, owner.handle(ble.descriptor, NameWire.encode(NameReport(3, "Retired"))))
        } finally { owner.close() }
    }
    @Test fun aliasesPersistAndTurningOffUsesLatestRemoteName() = runBlocking {
        val r = Rig(); var owner = r.owner()
        owner.awaitRefresh()
        owner.saveNickname(r.peer, "Personal", true)
        assertEquals("Personal", owner.displayName(r.peer))
        assertEquals("Original Mac", owner.deviceName(r.peer))
        owner.close()
        owner = r.owner()
        try {
            owner.awaitRefresh()
            val link = r.link("ble"); owner.available(link); owner.handle(link.descriptor, NameWire.encode())
            owner.handle(link.descriptor, NameWire.encode(NameReport(5, "Renamed Mac")))
            assertEquals("Personal", owner.displayName(r.peer))
            owner.saveNickname(r.peer, "Personal", false)
            assertEquals("Renamed Mac", owner.displayName(r.peer))
            assertEquals("Original Mac", r.trust.list(r.local.fingerprint).single().peer.deviceName)
            r.trust.remove(r.peer.deviceId); owner.invalidate(); owner.awaitRefresh()
            assertNull(owner.nickname(r.peer))
        } finally { owner.close() }
    }
    @Test fun failedPersistencePreservesDisplayAndIdentityResetClearsAliases() = runBlocking {
        val r = Rig(); val owner = r.owner()
        try {
            owner.awaitRefresh()
            owner.saveNickname(r.peer, "First", true)
            val before = r.saved!!.clone()
            r.failing = true
            try { owner.saveNickname(r.peer, "Second", true); fail("Storage failure ignored") } catch (_: Exception) {}
            assertEquals("First", owner.displayName(r.peer))
            assertArrayEquals(before, r.saved)
            r.failing = false
            r.identity.resetIdentity(); owner.invalidate(); owner.awaitRefresh()
            assertNull(owner.nickname(r.peer))
        } finally { owner.close() }
    }
    @Test fun offlineRenamePublishesLatestSnapshotOnNextCapableConnection() = runBlocking {
        val r = Rig(); val owner = r.owner()
        try {
            owner.awaitRefresh()
            r.identity.rename("Renamed Android")
            owner.awaitRefresh()
            val link = r.link("ble")
            owner.available(link)
            assertEquals(1, link.sent.size)
            assertTrue(NameWire.decode(link.sent.first())!!.first)
            owner.handle(link.descriptor, NameWire.encode())
            val report = NameWire.decode(link.sent.last())!!.second!!
            assertEquals("Renamed Android", report.name)
            assertEquals(1L, report.revision)
            r.identity.rename("Another name")
            owner.refresh()
            val newer = NameWire.decode(link.sent.last())!!.second!!
            assertEquals("Another name", newer.name)
            assertTrue(newer.revision > report.revision)
        } finally { owner.close() }
    }
    companion object {
        fun key(): KeyPair = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec("secp256r1")); generateKeyPair()
        }
        fun sign(key: KeyPair, bytes: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
            initSign(key.private); update(bytes); sign()
        }
    }
}
