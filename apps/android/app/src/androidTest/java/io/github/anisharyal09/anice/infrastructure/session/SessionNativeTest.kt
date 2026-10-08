// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.session

import android.os.SystemClock
import android.util.AtomicFile
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.identity.AndroidIdentityKeys
import io.github.anisharyal09.anice.infrastructure.identity.AndroidIdentityMetadata
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.identity.IdentityService
import java.io.File
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionNativeTest {
  private fun hex(text: String) = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

  private fun bytes(row: JSONObject, name: String) = hex(row.getString(name + "Hex"))

  private fun text(data: ByteArray) = data.joinToString("") { "%02x".format(it.toInt() and 255) }

  private fun identity(row: JSONObject, role: String): DeviceIdentity {
    val r = row.getJSONObject(role)
    return DeviceIdentity(
        r.getString("deviceId"),
        "Fixture",
        r.getString("platform"),
        Base64.getEncoder().encodeToString(bytes(r, "public")),
        r.getString("fingerprintHex"),
      )
      .validate()
  }

  private fun fixture(v: JSONObject, server: Boolean): SessionHandshakeEngine {
    val local = identity(v, if (server) "responder" else "initiator")
    val peer = identity(v, if (server) "initiator" else "responder")
    val stage = if (server) 2 else 3
    return SessionHandshakeEngine(
      local,
      server,
      { listOf(peer) },
      { local },
      { input ->
        assertArrayEquals(bytes(v, "signingInput$stage"), input)
        SessionProof(local, SessionSignature.coseToDer(bytes(v, "signature$stage")))
      },
      if (server) null else peer,
      SessionEphemeral.fixture(
        bytes(v, if (server) "y" else "x"),
        bytes(v, if (server) "yPublic" else "xPublic"),
      ),
      bytes(v, if (server) "cr" else "ci"),
    )
  }

  @Test
  fun nativeProviderConformance() = runBlocking {
    val context = InstrumentationRegistry.getInstrumentation().context
    val root =
      JSONObject(
        context.assets.open("session/session-vectors.json").bufferedReader().use { it.readText() }
      )
    val valid = root.getJSONArray("valid")
    val invalid = root.getJSONArray("invalid")
    assertTrue(valid.length() >= 3)
    assertTrue(invalid.length() >= 15)
    repeat(valid.length()) { i ->
      val v = valid.getJSONObject(i)
      val c = fixture(v, false)
      val s = fixture(v, true)
      val m1 = c.initiate()
      assertArrayEquals(bytes(v, "message1"), m1)
      val m2 = s.respond(m1)
      assertArrayEquals(bytes(v, "message2"), m2)
      val m3 = c.authenticateResponder(m2)
      assertArrayEquals(bytes(v, "message3"), m3)
      val m4 = s.authenticateInitiator(m3)
      assertArrayEquals(bytes(v, "message4"), m4)
      c.confirmResponder(m4)
      assertArrayEquals(bytes(v, "export-key-1"), c.export(bytes(v, "exportContext-key-1"), 32))
      c.close()
      s.close()
    }
    val v = valid.getJSONObject(0)
    repeat(invalid.length()) { i ->
      val row = invalid.getJSONObject(i)
      val stage = row.getInt("stage")
      val e = fixture(v, stage == 1 || stage == 3)
      when (stage) {
        2 -> e.initiate()
        3 -> e.respond(bytes(v, "message1"))
        4 -> {
          e.initiate()
          e.authenticateResponder(bytes(v, "message2"))
        }
      }
      val expected =
        when (row.getString("reason")) {
          "malformed" -> SessionFailure.MALFORMED
          "authentication" -> SessionFailure.AUTHENTICATION
          "untrustedPeer" -> SessionFailure.UNTRUSTED_PEER
          "unsupportedProfile" -> SessionFailure.UNSUPPORTED_PROFILE
          else -> error("Unknown fixture reason")
        }
      try {
        when (stage) {
          1 -> e.respond(bytes(row, "wire"))
          2 -> e.authenticateResponder(bytes(row, "wire"))
          3 -> e.authenticateInitiator(bytes(row, "wire"))
          4 -> e.confirmResponder(bytes(row, "wire"))
        }
        fail("Accepted ${row.getString("name")}")
      } catch (error: SessionException) {
        assertEquals(expected, error.reason)
      }
      assertEquals(HandshakeStage.CLOSED, e.stage)
    }
  }

  @Test
  fun protectedKeyInterchange(): Unit = runBlocking {
    val run = InstrumentationRegistry.getArguments().getString("aniceSessionRun")
    assumeTrue("Run through scripts/verify-session-interchange.py", run != null)
    require(UUID.fromString(run).toString() == run)
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val directory =
      File(requireNotNull(context.getExternalFilesDir(null)), "session-interchange-$run").apply {
        mkdirs()
      }
    val namespace = "anice.test.session.$run."
    val metadataName = "test-session-$run.json"
    val keys = AndroidIdentityKeys()
    val identity =
      IdentityService(
        AndroidIdentityMetadata(context, metadataName),
        keys,
        { "Session test" },
        namespace,
      )
    val deadline = SystemClock.elapsedRealtime() + 90_000
    fun awaitFile(name: String): JSONObject {
      val file = File(directory, name)
      while (!file.exists() && SystemClock.elapsedRealtime() < deadline) Thread.sleep(50)
      assertTrue("Interchange timed out waiting for ${file.absolutePath}", file.exists())
      return JSONObject(file.readText())
    }
    fun publish(name: String, row: JSONObject) {
      val file = File(directory, name)
      val temp = File(directory, "$name.tmp")
      temp.writeText(row.toString())
      check(temp.renameTo(file))
    }
    var engine: SessionHandshakeEngine? = null
    try {
      publish("bootstrap.json", JSONObject().put("directory", directory.absolutePath))
      val peer = DeviceIdentity.fromJson(awaitFile("server.json").getJSONObject("identity"))
      val local = identity.getOrCreateIdentity().identity
      val c =
        SessionHandshakeEngine(
          local,
          false,
          { listOf(peer) },
          { identity.getOrCreateIdentity().identity },
          { input ->
            identity.sign(input).let { SessionProof(it.snapshot.identity, it.signature) }
          },
          peer,
        )
      engine = c
      publish(
        "client.json",
        JSONObject().put("identity", local.toJson()).put("message1Hex", text(c.initiate())),
      )
      val m2 = bytes(awaitFile("message2.json"), "message2")
      publish("message3.json", JSONObject().put("message3Hex", text(c.authenticateResponder(m2))))
      c.confirmResponder(bytes(awaitFile("message4.json"), "message4"))
      val contextBytes = "aniCe session interchange v1".toByteArray(Charsets.UTF_8)
      val digest = SessionCrypto.hash(c.export(contextBytes, 32))
      assertEquals(local, identity.getOrCreateIdentity().identity)
      publish(
        "result.json",
        JSONObject().put("exportDigestHex", text(digest)).put("stage", c.stage.name),
      )
      // Confirm the harness received the result before deleting disposable exchange files.
      awaitFile("ack.json")
    } finally {
      engine?.close()
      keys.aliases().filter { it.startsWith(namespace) }.forEach(keys::delete)
      AtomicFile(File(context.noBackupFilesDir, metadataName)).delete()
      assertTrue(keys.aliases().none { it.startsWith(namespace) })
      assertFalse(File(context.noBackupFilesDir, metadataName).exists())
      directory.deleteRecursively()
    }
  }
}
