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

internal class NsdResolutionFailure(val code: Int) :
    Exception("Local-network discovery failed ($code). Retry.")

internal data class LanEndpoint(val network: Network, val address: InetAddress, val port: Int)

internal object LanAddress {
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

internal class AndroidLanDiscovery(context: Context, profile: SessionProfile = SessionProfile.STANDARD) {
    private val type = if (profile == SessionProfile.STANDARD) TYPE else "_anicebulk._tcp"
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val executor = Executor { it.run() }

    suspend fun discover(network: Network, links: () -> LinkProperties?): List<LanEndpoint> {
        val found = linkedMapOf<String, NsdServiceInfo>()
        val failure = CompletableDeferred<Unit>()
        val stopped = java.util.concurrent.atomic.AtomicBoolean(false)
        val listener =
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) {
                    if (stopped.get()) stop(this)
                }

                override fun onStartDiscoveryFailed(type: String, code: Int) {
                    failure.completeExceptionally(NsdResolutionFailure(code))
                }

                override fun onStopDiscoveryFailed(type: String, code: Int) {
                    failure.completeExceptionally(NsdResolutionFailure(code))
                }

                override fun onDiscoveryStopped(type: String) {
                    if (!stopped.get())
                        failure.completeExceptionally(
                            IllegalStateException("Local-network discovery stopped. Retry.")
                        )
                }

                override fun onServiceFound(service: NsdServiceInfo) {
                    synchronized(found) {
                        if (
                            !stopped.get() &&
                                found.size < 8 &&
                                service.serviceType.trimEnd('.') == type
                        ) {
                            if (
                                Build.VERSION.SDK_INT < 33 ||
                                    service.network == null ||
                                    service.network == network
                            )
                                found.putIfAbsent(service.serviceName, service)
                        }
                    }
                }

                override fun onServiceLost(service: NsdServiceInfo) {
                    synchronized(found) { found.remove(service.serviceName) }
                }
            }
        // Older framework NSD needs multicast reception only during this bounded foreground browse.
        val multicast =
            wifi.createMulticastLock("aniCe LAN discovery").apply { setReferenceCounted(false) }
        if (Build.VERSION.SDK_INT < 34) multicast.acquire()
        try {
            try {
                if (Build.VERSION.SDK_INT >= 33)
                    nsd.discoverServices(
                        type,
                        NsdManager.PROTOCOL_DNS_SD,
                        network,
                        executor,
                        listener,
                    )
                else nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
                withTimeoutOrNull(15000) { failure.await() }
            } finally {
                stopped.set(true)
                stop(listener)
            }
            val services = synchronized(found) { found.values.toList() }
            val endpoints = linkedMapOf<String, LanEndpoint>()
            for (service in services) {
                val resolved =
                    try {
                        resolve(service)
                    } catch (error: NsdResolutionFailure) {
                        if (error.code == NsdManager.FAILURE_ALREADY_ACTIVE) throw error
                        continue
                    }
                val properties = links() ?: error("Wi-Fi network changed. Retry.")
                if (
                    !resolved.attributes["v"].contentEquals(byteArrayOf(49)) ||
                        resolved.port !in 1..65535
                )
                    continue
                if (
                    Build.VERSION.SDK_INT >= 33 &&
                        resolved.network != null &&
                        resolved.network != network
                )
                    continue
                val addresses =
                    if (Build.VERSION.SDK_INT >= 34) resolved.hostAddresses
                    else listOfNotNull(resolved.host)
                val iface = properties.interfaceName?.let { NetworkInterface.getByName(it) }
                for (address in addresses) {
                    val scoped =
                        try {
                            LanAddress.scoped(address, iface?.index)
                        } catch (_: IllegalArgumentException) {
                            continue
                        } catch (_: UnknownHostException) {
                            continue
                        }
                    if (!LanAddress.local(scoped, properties)) continue
                    val key = "${scoped.hostAddress}:${resolved.port}"
                    if (endpoints.size < 8)
                        endpoints.putIfAbsent(key, LanEndpoint(network, scoped, resolved.port))
                }
            }
            return endpoints.values.toList()
        } finally {
            if (multicast.isHeld) multicast.release()
        }
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
