// SPDX-License-Identifier: GPL-3.0-or-later
// Assembles shared identity, trust and independent transport owners for the Android process.
package io.github.anisharyal09.anice

import android.app.Application
import android.os.Build
import io.github.anisharyal09.anice.infrastructure.identity.AndroidIdentityKeys
import io.github.anisharyal09.anice.infrastructure.identity.AndroidIdentityMetadata
import io.github.anisharyal09.anice.infrastructure.identity.IdentityService

class AniCeApplication : Application() {
    val sessionPeers = io.github.anisharyal09.anice.infrastructure.session.SessionPeerReservation()
    private val lanOwner = lazy { io.github.anisharyal09.anice.infrastructure.lan.LanSessionController(this) }
    val lanSessionController get() = lanOwner.value
    // UI and system-bound probe share one transport/operation owner; sessions never enter durable storage.
    private val bleOwner = lazy {
        io.github.anisharyal09.anice.infrastructure.session.SessionController(this)
    }

    val sessionController get() = bleOwner.value
    private fun invalidateSessions() {
        if (bleOwner.isInitialized()) bleOwner.value.securityInvalidated()
        if (lanOwner.isInitialized()) lanOwner.value.securityInvalidated()
    }

    @Volatile
    private var sharedTrust: io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustStore? =
        null
    var trustStore: io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustStore
        get() =
            synchronized(this) {
                sharedTrust
                    ?: io.github.anisharyal09.anice.infrastructure.pairing
                        .PeerTrustStore(java.io.File(noBackupFilesDir, "trusted_peers.json"))
                        .also { it.onInvalidated = ::invalidateSessions; sharedTrust = it }
            }
        set(value) {
            invalidateSessions()
            synchronized(this) { value.onInvalidated = ::invalidateSessions; sharedTrust = value }
        }

    // Share one service across activity recreation so identity operations stay serialized.
    val identityService by lazy {
        IdentityService(AndroidIdentityMetadata(this), AndroidIdentityKeys(), { Build.MODEL })
            .also { it.onInvalidated = ::invalidateSessions }
    }
}
