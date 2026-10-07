// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.pairing

import io.github.anisharyal09.anice.infrastructure.identity.*
import java.security.*
import java.security.spec.ECGenParameterSpec
import javax.crypto.KeyAgreement
import org.junit.Assert.*
import org.junit.Test

class PairingEngineTests {
  private class Memory : TrustPersistence {
    var data: ByteArray? = null
    var fail = false

    override fun read() = data

    override fun write(bytes: ByteArray) {
      check(!fail)
      data = bytes
    }
  }

  private class Keys : IdentityKeyStore {
    val values = mutableMapOf<String, KeyPair>()

    override fun aliases() = values.keys.toSet()

    override fun create(alias: String) {
      values[alias] = key()
    }

    override fun publicKey(alias: String) =
        values[alias]?.let { IdentityCrypto.exportPublicKey(it.public) }

    override fun protection(alias: String) = KeyProtection.PLATFORM

    override fun sign(alias: String, message: ByteArray) = signature(values[alias]!!, message)

    override fun delete(alias: String) {
      values.remove(alias)
    }
  }

  private class Metadata : IdentityMetadataStore {
    var record: IdentityJournal? = null

    override fun read() = record

    override fun write(journal: IdentityJournal) {
      record = journal
    }
  }

  @Test
  fun corruptTrustFailsClosedWithoutReplacingTheFile() {
    val memory = Memory()
    memory.data = "invalid json".toByteArray()
    val original = memory.data!!.clone()
    assertThrows(TrustStoreCorruptException::class.java) { PeerTrustStore(memory) }
    assertArrayEquals(original, memory.data)
    val valid = PeerTrustStore(Memory())
    assertThrows(PairingException::class.java) {
      valid.activate("missing", ByteArray(32), ByteArray(0))
    }
    assertTrue(valid.list("anything").isEmpty())
  }

  @Test
  fun fullQRConsentPersistenceReceiptsAndAtomicFailure() {
    val memory = Memory()
    val store = PeerTrustStore(memory)
    val identity = IdentityService(Metadata(), Keys(), { "Android test" })
    val signing = key()
    val local = identity.getOrCreateIdentity().identity
    val mac =
        DeviceIdentity(
                DeviceIdentity.newId(),
                "Mac test",
                "macos",
                IdentityCrypto.encodeBase64(IdentityCrypto.exportPublicKey(signing.public)),
                IdentityCrypto.fingerprint(IdentityCrypto.exportPublicKey(signing.public)),
            )
            .validate()
    val macBytes = mac.toJson().toString().toByteArray()
    val qr =
        PairingQR(
            PairingCodec.random(16),
            PairingCodec.random(32),
            PairingCodec.hash(IdentityCrypto.decodeBase64(mac.publicKey)),
        )
    val sent = mutableListOf<ByteArray>()
    val events = mutableListOf<String>()
    val engine =
        PairingEngine(
            PairingMethod.QR,
            qr,
            byteArrayOf(),
            identity,
            store,
            { sent.add(it) },
            { name, _ -> events.add(name) },
        )
    val sn = PairingCodec.random(32)
    engine.receive(PairingCodec.message(2, byteArrayOf(1), qr.rendezvous, sn))
    val hello = PairingCodec.unpack(sent.removeAt(0), 3, 4)
    val ephemeral = key()
    val sp = IdentityCrypto.exportPublicKey(ephemeral.public)
    val t =
        PairingCodec.fields(
            "aniCe pairing v1".toByteArray(),
            byteArrayOf(1),
            qr.rendezvous,
            hello[2],
            sn,
            hello[3],
            sp,
        )
    val h = PairingCodec.hash(t)
    val shared =
        KeyAgreement.getInstance("ECDH").run {
          init(ephemeral.private)
          doPhase(IdentityCrypto.publicKey(hello[3]), true)
          generateSecret()
        }
    val k =
        PairingCodec.hkdf(
            shared,
            qr.secret,
            PairingCodec.fields("aniCe qr bootstrap v1".toByteArray(), h),
        )
    val server = PairingChannel(k, t, true)
    engine.receive(
        PairingCodec.message(
            4,
            sn,
            sp,
            PairingCodec.mac(PairingCodec.derive(k, "server-auth", h), t),
        ))
    assertArrayEquals(
        PairingCodec.mac(PairingCodec.derive(k, "client-auth", h), t),
        PairingCodec.unpack(sent.removeAt(0), 5, 1)[0],
    )
    engine.receive(PairingCodec.message(6, server.confirm()))
    val clientBytes = PairingCodec.unpack(server.open(sent.removeAt(0)), 10, 1)[0]
    engine.receive(server.seal(PairingCodec.message(10, macBytes)))
    val clientSignature = PairingCodec.unpack(server.open(sent.removeAt(0)), 11, 1)[0]
    assertTrue(
        IdentityCrypto.verify(
            IdentityCrypto.decodeBase64(local.publicKey),
            PairingCodec.proof(h, clientBytes, macBytes, 1),
            clientSignature,
        ))
    try {
      engine.receive(server.seal(PairingCodec.message(11, byteArrayOf(1))))
      fail("Invalid identity proof accepted")
    } catch (_: IllegalArgumentException) {}
    assertTrue(store.list(local.fingerprint).isEmpty())
    engine.receive(
        server.seal(
            PairingCodec.message(
                11,
                signature(signing, PairingCodec.proof(h, clientBytes, macBytes, 2)),
            )))
    assertTrue(events.contains("approval"))
    engine.approve()
    assertArrayEquals(PairingCodec.message(12), server.open(sent.removeAt(0)))
    assertTrue(store.list(local.fingerprint).isEmpty())
    engine.receive(server.seal(PairingCodec.message(12)))
    val hash = PairingCodec.hash(PairingCodec.proof(h, clientBytes, macBytes))
    val receipt = PairingCodec.unpack(server.open(sent.removeAt(0)), 13, 1)[0]
    assertTrue(
        IdentityCrypto.verify(
            IdentityCrypto.decodeBase64(local.publicKey),
            PairingCodec.receipt(hash, 1),
            receipt,
        ))
    assertTrue(store.list(local.fingerprint).isEmpty())
    try {
      engine.receive(server.seal(PairingCodec.message(13, byteArrayOf(1))))
      fail("Invalid receipt accepted")
    } catch (_: IllegalArgumentException) {}
    assertTrue(store.list(local.fingerprint).isEmpty())
    engine.receive(
        server.seal(PairingCodec.message(13, signature(signing, PairingCodec.receipt(hash, 2)))))
    assertTrue(events.contains("paired"))
    assertEquals(mac, store.list(local.fingerprint).single().peer)
    val active = store.list(local.fingerprint).single()
    store.prepare(active.copy(active = false, receipt = null))
    store.discardPending()
    assertEquals(1, store.list(local.fingerprint).size)
    memory.fail = true
    try {
      store.remove(mac.deviceId)
      fail("Write failure ignored")
    } catch (_: IllegalStateException) {}
    assertEquals(1, store.list(local.fingerprint).size)
    memory.fail = false
    engine.close()
    val reopened = PeerTrustStore(memory)
    assertEquals(1, reopened.list(local.fingerprint).size)
    reopened.remove(mac.deviceId)
    assertTrue(reopened.list(local.fingerprint).isEmpty())
  }

  @Test
  fun repairingAtCapacityReplacesExistingPeerAndRejectsNewPeer() {
    val memory = Memory()
    var store = PeerTrustStore(memory)
    val key = key()
    val pub = IdentityCrypto.encodeBase64(IdentityCrypto.exportPublicKey(key.public))
    val fp = IdentityCrypto.fingerprint(IdentityCrypto.exportPublicKey(key.public))
    val localFp = "local-fingerprint-test"

    val peer0Id = DeviceIdentity.newId()
    for (i in 0 until 128) {
      val id = if (i == 0) peer0Id else DeviceIdentity.newId()
      val peer = DeviceIdentity(id, "Peer $i", "macos", pub, fp).validate()
      val hash = ByteArray(32) { (i and 0xff).toByte() }
      val receipt = signature(key, PairingCodec.receipt(hash, 2))
      store.prepare(PeerTrustRecord(peer, localFp, PairingMethod.QR, 1000L + i, hash, null, false))
      store.activate(id, hash, receipt)
    }
    assertEquals(128, store.list(localFp).size)

    // Attempting to add a 129th new peer is rejected
    val newPeerId = DeviceIdentity.newId()
    val newPeer = DeviceIdentity(newPeerId, "Peer 129", "macos", pub, fp).validate()
    val newHash = ByteArray(32) { 129.toByte() }
    assertThrows(IllegalArgumentException::class.java) {
      store.prepare(
          PeerTrustRecord(newPeer, localFp, PairingMethod.QR, 2000L, newHash, null, false))
    }

    // Re-pairing existing peer0 succeeds at capacity
    val updatedPeer0 = DeviceIdentity(peer0Id, "Peer 0 Renamed", "macos", pub, fp).validate()
    val updatedHash = ByteArray(32) { 0xee.toByte() }
    val updatedReceipt = signature(key, PairingCodec.receipt(updatedHash, 2))
    val pending =
        PeerTrustRecord(updatedPeer0, localFp, PairingMethod.QR, 3000L, updatedHash, null, false)
    val original = store.list(localFp).first { it.peer.deviceId == peer0Id }
    val differentKey = key()
    val changedPeer =
        DeviceIdentity(
                peer0Id,
                "Changed key",
                "macos",
                IdentityCrypto.encodeBase64(IdentityCrypto.exportPublicKey(differentKey.public)),
                IdentityCrypto.fingerprint(IdentityCrypto.exportPublicKey(differentKey.public)),
            )
            .validate()
    assertThrows(IllegalArgumentException::class.java) {
      store.prepare(pending.copy(peer = changedPeer))
    }
    store.prepare(pending)
    assertEquals(original, store.list(localFp).first { it.peer.deviceId == peer0Id })
    // Restart before receipt exchange must discard the extra pending row, retaining active trust.
    store = PeerTrustStore(memory)
    assertEquals(128, store.list(localFp).size)
    assertArrayEquals(
        original.transcriptHash,
        store.list(localFp).first { it.peer.deviceId == peer0Id }.transcriptHash)
    store.prepare(pending)
    store.discardPending()
    assertEquals(original.peer, store.list(localFp).first { it.peer.deviceId == peer0Id }.peer)
    store.prepare(pending)
    memory.fail = true
    assertThrows(IllegalStateException::class.java) {
      store.activate(peer0Id, updatedHash, updatedReceipt)
    }
    memory.fail = false
    assertEquals(original.peer, store.list(localFp).first { it.peer.deviceId == peer0Id }.peer)
    store.activate(peer0Id, updatedHash, updatedReceipt)

    assertEquals(128, store.list(localFp).size)
    val reloaded = PeerTrustStore(memory)
    assertEquals(128, reloaded.list(localFp).size)
    val peer0Record = reloaded.list(localFp).first { it.peer.deviceId == peer0Id }
    assertArrayEquals(updatedHash, peer0Record.transcriptHash)
    assertEquals("Peer 0 Renamed", peer0Record.peer.deviceName)
  }

  companion object {
    private fun key() =
        KeyPairGenerator.getInstance("EC").run {
          initialize(ECGenParameterSpec("secp256r1"))
          generateKeyPair()
        }

    private fun signature(key: KeyPair, message: ByteArray): ByteArray =
        Signature.getInstance("SHA256withECDSA").run {
          initSign(key.private)
          update(message)
          sign()
        }
  }
}
