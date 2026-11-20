// SPDX-License-Identifier: GPL-3.0-or-later
// Checks SAS fixtures against Android's actual JCA providers without changing application trust or identity.
package io.github.anisharyal09.anice.infrastructure.pairing

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.identity.IdentityCrypto
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec
import javax.crypto.KeyAgreement
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PairingSasNativeTest {
    private fun hex(text: String) = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun nativeProviderMatchesBothSharedVectorsIncludingLeadingZero() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val root = JSONObject(assets.open("sas-vectors.json").bufferedReader().use { it.readText() })
        val vectors = root.getJSONArray("valid")
        assertEquals(2, vectors.length())
        val curve = AlgorithmParameters.getInstance("EC").apply {
            init(ECGenParameterSpec("secp256r1"))
        }.getParameterSpec(ECParameterSpec::class.java)
        val privateKey = KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger.ONE, curve))
        repeat(vectors.length()) { index ->
            val row = vectors.getJSONObject(index)
            fun bytes(name: String) = hex(row.getString(name + "Hex"))
            for ((name, platform) in listOf("clientIdentity" to "android", "serverIdentity" to "macos")) {
                val identity = DeviceIdentity.fromJson(JSONObject(String(bytes(name), Charsets.UTF_8)))
                assertEquals(platform, identity.platform)
            }
            val ci = PairingSas.identityCommitment(1, bytes("clientIdentitySalt"), bytes("clientIdentity"))
            val si = PairingSas.identityCommitment(2, bytes("serverIdentitySalt"), bytes("serverIdentity"))
            assertArrayEquals(bytes("clientIdentityCommitment"), ci)
            assertArrayEquals(bytes("serverIdentityCommitment"), si)
            val transcript = PairingSas.transcript(bytes("rendezvous"), bytes("serverNonce"),
                bytes("clientCommitment"), bytes("serverCommitment"), bytes("clientPublic"),
                bytes("serverPublic"), bytes("clientNonce"), bytes("serverComparisonNonce"), ci, si)
            assertArrayEquals(bytes("transcript"), transcript)
            val shared = KeyAgreement.getInstance("ECDH").run {
                init(privateKey); doPhase(IdentityCrypto.publicKey(bytes("serverPublic")), true)
                generateSecret()
            }
            assertArrayEquals(bytes("sharedSecret"), shared)
            val key = PairingSas.bootstrap(shared, transcript)
            assertArrayEquals(bytes("bootstrapKey"), key)
            assertEquals(row.getString("digits"), PairingSas.digits(key, transcript))
            val client = PairingChannel(key, transcript, false)
            val server = PairingChannel(key.clone(), transcript, true)
            val comparison = client.seal(PairingCodec.message(15))
            assertArrayEquals(bytes("encryptedComparison"), comparison)
            assertArrayEquals(PairingCodec.message(15), server.open(comparison))
            assertThrows(Exception::class.java) { server.open(comparison) }
            client.destroy(); server.destroy(); shared.fill(0)
        }
    }
}
