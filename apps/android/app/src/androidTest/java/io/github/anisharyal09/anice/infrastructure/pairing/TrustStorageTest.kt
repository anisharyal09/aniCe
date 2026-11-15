// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies native trust-journal backup recovery without touching production credentials.
package io.github.anisharyal09.anice.infrastructure.pairing

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.identity.IdentityCrypto
import java.io.File
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TrustStorageTest {
    @Test fun backupOnlyTrustJournalRetainsActivePeerAndReceipt() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.noBackupFilesDir, "trust-test-${DeviceIdentity.newId()}.json")
        val backup = File(file.path + ".bak")
        val keys = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec("secp256r1")); generateKeyPair()
        }
        val publicKey = IdentityCrypto.exportPublicKey(keys.public)
        val peer = DeviceIdentity(DeviceIdentity.newId(), "Recovery peer", "macos",
            IdentityCrypto.encodeBase64(publicKey), IdentityCrypto.fingerprint(publicKey)).validate()
        val hash = ByteArray(32) { it.toByte() }
        val receipt = Signature.getInstance("SHA256withECDSA").run {
            initSign(keys.private); update(PairingCodec.receipt(hash, 2)); sign()
        }
        try {
            val store = PeerTrustStore(file)
            store.prepare(PeerTrustRecord(peer, "local", PairingMethod.QR, 1L, hash))
            store.activate(peer.deviceId, hash, receipt)
            assertTrue(file.renameTo(backup))
            assertFalse(file.exists())
            val restored = PeerTrustStore(file).list("local").single()
            assertEquals(peer, restored.peer)
            assertArrayEquals(hash, restored.transcriptHash)
            assertArrayEquals(receipt, restored.receipt)
            assertTrue(restored.active)
            assertFalse(backup.exists())
        } finally { listOf(file, backup, File(file.path + ".new")).forEach { it.delete() } }
    }
}
