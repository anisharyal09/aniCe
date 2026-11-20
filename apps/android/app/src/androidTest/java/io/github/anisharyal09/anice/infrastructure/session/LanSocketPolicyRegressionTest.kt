// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies public TCP timeout configuration does not close the network-bound socket or discard complete frames.
package io.github.anisharyal09.anice.infrastructure.session

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.lan.*
import java.io.DataInputStream
import java.net.Inet4Address
import java.net.ServerSocket
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanSocketPolicyRegressionTest {
    @Test fun configuringTcpUserTimeoutKeepsTheOriginalSocketUsable() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assumeTrue("Requires an isolated preview or native-regression app",
            context.packageName in setOf("io.github.anisharyal09.anice.preview",
                "io.github.anisharyal09.anice.preview.transfer.regression"))
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = manager.allNetworks.firstOrNull {
            manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
        assumeTrue("Requires a usable Wi-Fi interface", network != null)
        val address = manager.getLinkProperties(network!!)?.linkAddresses?.firstOrNull {
            it.address is Inet4Address && !it.address.isLoopbackAddress
        }?.address
        assumeTrue("Requires an IPv4 Wi-Fi address", address != null)
        val server = withContext(Dispatchers.IO) { ServerSocket(0, 1, address).apply { soTimeout = 5_000 } }
        val transport = AndroidLanTransport(this)
        val incoming = async(Dispatchers.IO) { server.accept().apply { soTimeout = 5_000 } }
        var peer: java.net.Socket? = null
        try {
            transport.connect(LanEndpoint(network, address!!, server.localPort))
            val socket = withTimeout(6_000) { incoming.await() }.also { peer = it }
            assertTrue("The public TCP user-timeout option was not configured on this kernel",
                transport.tcpUserTimeoutConfigured)
            val envelope = byteArrayOf(6, 1, 2, 3)
            withTimeout(5_000) { transport.submit(envelope) }
            val body = withContext(Dispatchers.IO) {
                val input = DataInputStream(socket.getInputStream())
                assertEquals(1, input.readUnsignedByte())
                assertEquals(envelope.size, input.readInt())
                ByteArray(envelope.size).also(input::readFully)
            }
            assertArrayEquals(envelope, body)
            val reply = byteArrayOf(6, 4, 5, 6)
            withContext(Dispatchers.IO) {
                socket.getOutputStream().write(LanFraming.encode(reply))
                socket.shutdownOutput()
            }
            val delivered = mutableListOf<ByteArray>()
            try {
                withTimeout(5_000) { transport.receive { delivered.add(it) } }
                fail("Clean FIN did not end the transport")
            } catch (_: java.io.EOFException) {}
            assertEquals(1, delivered.size)
            assertArrayEquals(reply, delivered.single())
        } finally {
            transport.close()
            withContext(NonCancellable + Dispatchers.IO) {
                peer?.close()
                server.close()
            }
            incoming.cancelAndJoin()
        }
    }
}
