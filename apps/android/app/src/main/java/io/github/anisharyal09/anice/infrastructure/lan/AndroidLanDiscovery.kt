// SPDX-License-Identifier: GPL-3.0-or-later
// Resolves bounded untrusted Bonjour locators on the current Wi-Fi network.
@file:Suppress("DEPRECATION") // API 29–33 require legacy DNS-SD resolution.

package io.github.anisharyal09.anice.infrastructure.lan

import io.github.anisharyal09.anice.infrastructure.session.SessionProfile
import android.content.Context
import android.net.*
import android.net.nsd.*
import android.net.wifi.WifiManager
import android.os.Build
import java.net.*
import java.util.concurrent.Executor
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal class NsdResolutionFailure(val code: Int) :
    Exception("Local-network discovery failed ($code). Retry.")

internal data class LanEndpoint(val network: Network, val address: InetAddress, val port: Int, val profile: SessionProfile = SessionProfile.STANDARD)

internal object LanAddress {
    fun retainsLocalAddress(bound: InetAddress?, initial: Set<InetAddress>, current: Set<InetAddress>): Boolean =
        if (bound != null) bound in current else initial.isEmpty() || current.intersect(initial).isNotEmpty()

    fun scoped(address: InetAddress, interfaceIndex: Int?): InetAddress {
        if (address !is Inet6Address || !address.isLinkLocalAddress) return address
        val index = requireNotNull(interfaceIndex) { "Wi-Fi interface is unavailable. Retry." }
        require(index > 0) { "Wi-Fi interface is unavailable. Retry." }
        require(address.scopeId == 0 || address.scopeId == index) {
            "Local-network address belongs to another interface."
        }
        return Inet6Address.getByAddress(null, address.address, index)
    }

    fun local(address: InetAddress, links: LinkProperties): Boolean =
        !address.isAnyLocalAddress &&
            !address.isLoopbackAddress &&
            !address.isMulticastAddress &&
            links.routes.any {
                !it.hasGateway() && it.destination.prefixLength > 0 && it.matches(address)
            }
}

internal class AndroidLanDiscovery(context: Context, private val profile: SessionProfile = SessionProfile.STANDARD) {
    private val type = if (profile == SessionProfile.BULK_PROBE) "_anicebulk._tcp" else TYPE
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val executor = Executor { it.run() }

    suspend fun discover(network: Network, links: () -> LinkProperties?): List<LanEndpoint> =
        endpoints(network, links).toList()

    fun endpoints(network: Network, links: () -> LinkProperties?): Flow<LanEndpoint> = channelFlow {
        val candidates = LanDiscoveryCandidates<NsdServiceInfo>()
        val stopped = java.util.concurrent.atomic.AtomicBoolean(false)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) { if (stopped.get()) stop(this) }
            override fun onStartDiscoveryFailed(type: String, code: Int) {
                candidates.close(NsdResolutionFailure(code))
            }
            override fun onStopDiscoveryFailed(type: String, code: Int) {
                candidates.close(NsdResolutionFailure(code))
            }
            override fun onDiscoveryStopped(type: String) {
                if (!stopped.get()) candidates.close(IllegalStateException("Local-network discovery stopped. Retry."))
            }
            override fun onServiceFound(service: NsdServiceInfo) {
                if (service.serviceType.trimEnd('.') == type &&
                    (Build.VERSION.SDK_INT < 33 || service.network == null || service.network == network))
                    candidates.offer(service.serviceName, service)
            }
            override fun onServiceLost(service: NsdServiceInfo) { candidates.lost(service.serviceName) }
        }
        val multicast = wifi.createMulticastLock("aniCe LAN discovery").apply { setReferenceCounted(false) }
        if (Build.VERSION.SDK_INT < 34) multicast.acquire()
        try {
            if (Build.VERSION.SDK_INT >= 33)
                nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, network, executor, listener)
            else nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
            // Resolution and authentication overlap the browse; neither may restart its deadline.
            withTimeoutOrNull(15000) {
                candidates.endpoints(key = { "${it.address.hostAddress}:${it.port}" }) { service ->
                    resolveEndpoints(service, network, links)
                }.collect { send(it) }
            }
        } finally {
            stopped.set(true)
            candidates.close()
            try { stop(listener) }
            finally { if (multicast.isHeld) multicast.release() }
        }
    }.buffer(8)

    private suspend fun resolveEndpoints(service: NsdServiceInfo, network: Network,
        links: () -> LinkProperties?): List<LanEndpoint> {
        val resolved = try { resolve(service) }
        catch (error: NsdResolutionFailure) {
            if (error.code == NsdManager.FAILURE_ALREADY_ACTIVE) throw error
            return emptyList()
        }
        val properties = links() ?: error("Wi-Fi network changed. Retry.")
        val revision2 = type == TYPE && resolved.attributes["v"].contentEquals(byteArrayOf(50))
        val revision3 = type == TYPE && resolved.attributes["v"].contentEquals(byteArrayOf(51))
        if (!(resolved.attributes["v"].contentEquals(byteArrayOf(49)) || revision2 || revision3) || resolved.port !in 1..65535)
            return emptyList()
        if (Build.VERSION.SDK_INT >= 33 && resolved.network != null && resolved.network != network)
            return emptyList()
        val addresses = if (Build.VERSION.SDK_INT >= 34) resolved.hostAddresses else listOfNotNull(resolved.host)
        val iface = properties.interfaceName?.let { NetworkInterface.getByName(it) }
        val endpoints = mutableListOf<LanEndpoint>()
        for (address in addresses) {
            val scoped = try { LanAddress.scoped(address, iface?.index) }
            catch (_: IllegalArgumentException) { continue }
            catch (_: UnknownHostException) { continue }
            if (LanAddress.local(scoped, properties) && endpoints.size < 8)
                endpoints.add(LanEndpoint(network, scoped, resolved.port, if (revision3) SessionProfile.LAN_TRANSFER_512 else if (revision2) SessionProfile.LAN_TRANSFER else profile))
        }
        return endpoints
    }

    private fun stop(listener: NsdManager.DiscoveryListener) {
        try {
            nsd.stopServiceDiscovery(listener)
        } catch (_: IllegalArgumentException) {
            /* Startup may still be pending; its callback stops the browse. */
        }
    }

    private suspend fun resolve(service: NsdServiceInfo): NsdServiceInfo {
        if (Build.VERSION.SDK_INT >= 34) {
            val result = CompletableDeferred<NsdServiceInfo>()
            val callback =
                object : NsdManager.ServiceInfoCallback {
                    override fun onServiceInfoCallbackRegistrationFailed(code: Int) {
                        result.completeExceptionally(NsdResolutionFailure(code))
                    }

                    override fun onServiceUpdated(info: NsdServiceInfo) {
                        result.complete(info)
                    }

                    override fun onServiceLost() {
                        result.completeExceptionally(
                            IllegalStateException("Local-network service disappeared.")
                        )
                    }

                    override fun onServiceInfoCallbackUnregistered() {}
                }
            nsd.registerServiceInfoCallback(service, executor, callback)
            try {
                return withTimeout(5000) { result.await() }
            } finally {
                try {
                    nsd.unregisterServiceInfoCallback(callback)
                } catch (_: IllegalArgumentException) {}
            }
        }
        val request = lane.begin()
        try {
            nsd.resolveService(
                service,
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
                        lane.finish(request.token, Result.failure(NsdResolutionFailure(code)))
                    }

                    override fun onServiceResolved(info: NsdServiceInfo) {
                        lane.finish(request.token, Result.success(info))
                    }
                },
            )
        } catch (error: RuntimeException) {
            lane.finish(request.token, Result.failure(error))
            throw error
        }
        // Await cancellation never releases the native slot; only a terminal callback can do so.
        return withTimeout(5000) { request.result.await() }
    }

    companion object {
        private val lane = LegacyResolutionLane<NsdServiceInfo>()
        const val TYPE = "_anice._tcp"
    }
}
