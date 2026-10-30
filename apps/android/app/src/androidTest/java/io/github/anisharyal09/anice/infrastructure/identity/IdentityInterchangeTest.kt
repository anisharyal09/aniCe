// SPDX-License-Identifier: GPL-3.0-or-later
// Exchanges isolated Android Keystore identity signatures with the host harness.
package io.github.anisharyal09.anice.infrastructure.identity

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/**
 * Instrumented test verifying actual cross-platform signature interchange with macOS.
 *
 * Controlled by the `aniceInterchange` instrumentation argument:
 * - "export": Creates an isolated Android Keystore key, signs a message, and writes out `android.json`.
 * - "verify": Reads `macos.json` exported by macOS, validates the identity, and verifies the signature.
 */
@RunWith(AndroidJUnit4::class)
class IdentityInterchangeTest {

    @Test
    fun executeInterchange() {
        val arguments = InstrumentationRegistry.getArguments()
        val mode = arguments.getString("aniceInterchange")
        assumeTrue("Run through the native interchange harness", mode != null)

        val context = ApplicationProvider.getApplicationContext<Context>()
        val exchangeDir = File(requireNotNull(context.getExternalFilesDir(null)), "identity-interchange").apply { mkdirs() }
        val testAliasPrefix = "anice.test.interchange."
        val metadataFile = "test-interchange-metadata.json"
        val metadata = AndroidIdentityMetadata(context, metadataFile)
        val keys = AndroidIdentityKeys()
        val service = IdentityService(metadata, keys, { "Android Interchange Test" }, testAliasPrefix)

        fun cleanup() {
            keys.aliases().filter { it.startsWith(testAliasPrefix) }.forEach(keys::delete)
            android.util.AtomicFile(File(context.noBackupFilesDir, metadataFile)).delete()
            File(exchangeDir, "android.json").delete()
            File(exchangeDir, "macos.json").delete()
            assertTrue("Test aliases remain after cleanup", keys.aliases().none { it.startsWith(testAliasPrefix) })
            assertFalse("Test metadata remains after cleanup", File(context.noBackupFilesDir, metadataFile).exists())
            assertFalse("Android test bundle remains after cleanup", File(exchangeDir, "android.json").exists())
            assertFalse("Mac test bundle remains after cleanup", File(exchangeDir, "macos.json").exists())
        }

        when (mode) {
            "export" -> {
                cleanup()
                val message = "aniCe Android-to-Mac interchange challenge: ${UUID.randomUUID()}".toByteArray(Charsets.UTF_8)
                val signatureResult = service.sign(message)

                val bundle = JSONObject().apply {
                    put("identity", signatureResult.snapshot.identity.toJson())
                    put("messageBase64", IdentityCrypto.encodeBase64(message))
                    put("signatureBase64", IdentityCrypto.encodeBase64(signatureResult.signature))
                }

                File(exchangeDir, "android.json").writeText(bundle.toString(2), Charsets.UTF_8)
            }
            "verify" -> {
                try {
                val macFile = File(exchangeDir, "macos.json")
                assertTrue("Missing macos.json bundle", macFile.exists())

                val bundle = JSONObject(macFile.readText(Charsets.UTF_8))
                assertEquals(setOf("identity", "messageBase64", "signatureBase64"), bundle.keys().asSequence().toSet())
                val identity = DeviceIdentity.fromJson(bundle.getJSONObject("identity"))
                identity.validate()
                assertEquals("macos", identity.platform)

                // The harness starts a separate instrumentation process for this phase.
                // Verify the exported Android identity survived that process boundary.
                val exported = JSONObject(File(exchangeDir, "android.json").readText(Charsets.UTF_8))
                val androidIdentity = DeviceIdentity.fromJson(exported.getJSONObject("identity"))
                assertEquals(androidIdentity, service.getOrCreateIdentity().identity)
                val restored = service.sign("Restart verification".toByteArray(Charsets.UTF_8))
                assertTrue(IdentityCrypto.verify(IdentityCrypto.decodeBase64(androidIdentity.publicKey),
                    "Restart verification".toByteArray(Charsets.UTF_8), restored.signature))

                val message = IdentityCrypto.decodeBase64(bundle.getString("messageBase64"))
                val signature = IdentityCrypto.decodeBase64(bundle.getString("signatureBase64"))

                val isValid = IdentityCrypto.verify(
                    IdentityCrypto.decodeBase64(identity.publicKey),
                    message,
                    signature
                )
                assertTrue("macOS signature failed verification on Android", isValid)
                assertFalse("Altered message was accepted", IdentityCrypto.verify(
                    IdentityCrypto.decodeBase64(identity.publicKey), message + byteArrayOf(0), signature))
                assertFalse("Malformed signature was accepted", IdentityCrypto.verify(
                    IdentityCrypto.decodeBase64(identity.publicKey), message, byteArrayOf(0)))
                assertFalse("Wrong public key was accepted", IdentityCrypto.verify(
                    IdentityCrypto.decodeBase64(androidIdentity.publicKey), message, signature))
                } finally { cleanup() }
            }
            "cleanup" -> cleanup()
            else -> error("Unknown interchange mode: $mode")
        }
    }
}
