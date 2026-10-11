// SPDX-License-Identifier: GPL-3.0-or-later
// Measures connected CPU and validation work without changing native ownership or generating traffic.
package io.github.anisharyal09.anice.features.backgroundprobe

import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import android.os.Process
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.session.*
import java.io.File
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PhysicalSessionIdleTest {
  @Test fun connectedIdleCpuAndNativeValidationBudget() = runBlocking {
    assumeTrue("Supply physicalIdle=ble after connecting the physical Mac",
      InstrumentationRegistry.getArguments().getString("physicalIdle") == "ble")
    val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
    val owner = app.sessionController
    withTimeout(180000) {
      while (withContext(Dispatchers.Main) {
        owner.state != ConnectionState.SECURED || owner.controlSupport != true
      }) delay(500)
    }
    val field = owner.javaClass.getDeclaredField("connection").apply { isAccessible = true }
    val engine = withContext(Dispatchers.Main) { field.get(owner) as SessionConnection }
    val channelField = engine.javaClass.getDeclaredField("channel").apply { isAccessible = true }
    val channel = withContext(Dispatchers.Main) { channelField.get(engine) as SecureSession }
    val identityFile = File(app.noBackupFilesDir, "identity-v1.json")
    val trustFile = File(app.noBackupFilesDir, "trusted_peers.json")
    val identityBefore = identityFile.readBytes()
    val trustBefore = trustFile.readBytes()
    val checks = withContext(Dispatchers.Main) { owner.receivedChecks }
    val pid = Process.myPid()
    suspend fun snapshot(): JSONObject = withContext(Dispatchers.Main) {
      assertEquals(pid, Process.myPid())
      assertEquals(owner.status, ConnectionState.SECURED, owner.state)
      assertEquals(true, owner.controlSupport)
      assertSame(engine, field.get(owner))
      assertFalse(engine.isClosed)
      assertEquals(checks, owner.receivedChecks)
      assertSame(channel, channelField.get(engine))
      JSONObject().put("pid", pid).put("elapsedMs", SystemClock.elapsedRealtime())
        .put("cpuMs", Process.getElapsedCpuTime()).put("identityLoads", app.identityService.identityLoads)
        .put("maintenanceRuns", engine.maintenanceRuns)
        .put("sent", channel.sent.toLong()).put("received", channel.received.toLong())
    }
    try {
      android.util.Log.i("aniCe-idle-test", "connected; keep display, charging and transport state unchanged")
      repeat(2) { delay(60000); snapshot() }
      val intervals = JSONArray()
      repeat(3) {
        val before = snapshot()
        repeat(5) { delay(60000); snapshot() }
        val after = snapshot()
        val elapsed = after.getLong("elapsedMs") - before.getLong("elapsedMs")
        val cpu = after.getLong("cpuMs") - before.getLong("cpuMs")
        val loads = after.getLong("identityLoads") - before.getLong("identityLoads")
        val records = after.getLong("sent") + after.getLong("received") - before.getLong("sent") - before.getLong("received")
        assertTrue(elapsed >= 300000)
        assertTrue("Idle storage polling exceeded encrypted-operation work", loads <= records * 8 + 8)
        intervals.put(JSONObject().put("before", before).put("after", after)
          .put("cpuPercentOneCore", 100.0 * cpu / elapsed))
        File(app.filesDir, "idle-cpu-optimization.json").writeText(intervals.toString(2))
      }
      assertEquals(3, intervals.length())
    } finally {
      assertArrayEquals(identityBefore, identityFile.readBytes())
      assertArrayEquals(trustBefore, trustFile.readBytes())
    }
  }
}
