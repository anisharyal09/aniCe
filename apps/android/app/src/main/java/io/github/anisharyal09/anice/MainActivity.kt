// SPDX-License-Identifier: GPL-3.0-or-later
// Assembles native presentation and coordinates transport-specific radio and lifecycle ownership.
package io.github.anisharyal09.anice

import android.os.Bundle
import android.view.KeyEvent
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import io.github.anisharyal09.anice.app.AppRoot
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityViewModel
import io.github.anisharyal09.anice.features.discovery.DiscoveryViewModel
import io.github.anisharyal09.anice.features.pairing.PairingViewModel
import io.github.anisharyal09.anice.features.session.SessionViewModel
import io.github.anisharyal09.anice.ui.theme.AniCeTheme

class MainActivity : ComponentActivity() {
    private lateinit var session: SessionViewModel
    private lateinit var pairing: PairingViewModel
    private lateinit var discovery: DiscoveryViewModel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        mediaNavigation(intent)
        enableEdgeToEdge()
        val service = (application as AniCeApplication).identityService
        // The activity hosts UI; its lifecycle ViewModel retains identity state during recreation.
        val factory = viewModelFactory { initializer { DeviceIdentityViewModel(service) } }
        val identity = ViewModelProvider(this, factory)[DeviceIdentityViewModel::class.java]
        val discoveryFactory = viewModelFactory { initializer { DiscoveryViewModel(application) } }
        discovery = ViewModelProvider(this, discoveryFactory)[DiscoveryViewModel::class.java]
        val pairingFactory = viewModelFactory { initializer { PairingViewModel(application) } }
        pairing = ViewModelProvider(this, pairingFactory)[PairingViewModel::class.java]
        val sessionFactory = viewModelFactory { initializer { SessionViewModel(application) } }
        session = ViewModelProvider(this, sessionFactory)[SessionViewModel::class.java]
        session.beforeConnect = {
            pairing.cancel()
            discovery.cancel()
        }
        pairing.beforePairing = {
            io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe.get(this).suspend()
            session.cancel()
            discovery.cancel()
        }
        pairing.trustRemoved = {
            io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe.get(this).stop("Trust changed. Set up automatic connection again.")
            session.cancel()
        }
        discovery.onBusyChanged = { busy ->
            val nearby = io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe.get(this)
            if (busy || pairing.busy) nearby.suspend() else nearby.resumeAfterOperation()
        }
        discovery.beforeStart = {
            io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe.get(this).suspend()
            session.cancelBluetooth()
            pairing.cancel()
        }
        identity.onIdentityReset = {
            (application as AniCeApplication).clipboard.preferences.clear()
            (application as AniCeApplication).clipboard.invalidate()
            io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe.get(this).stop("Identity changed. Set up automatic connection again.")
            session.cancel()
            pairing.cancel()
        }
        setContent { AniCeTheme { AppRoot(identity, discovery, pairing, session) } }
    }

    private fun mediaNavigation(intent: Intent?) {
        if(intent?.getBooleanExtra(io.github.anisharyal09.anice.features.nowplaying.MediaNotification.OPEN,false)==true) {
            (application as AniCeApplication).nowPlaying.openWorkspace()
            intent.removeExtra(io.github.anisharyal09.anice.features.nowplaying.MediaNotification.OPEN)
        }
    }
    private val remoteVolumeKeys=mutableSetOf<Int>()
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val direction=when(keyCode) { KeyEvent.KEYCODE_VOLUME_UP->1;KeyEvent.KEYCODE_VOLUME_DOWN->-1;else->0 }
        val owner=(application as AniCeApplication).nowPlaying
        if(direction!=0 && owner.foregroundVisible && owner.canControlOutputVolume) {
            remoteVolumeKeys.add(keyCode);owner.adjustOutputVolume(direction);return true
        }
        return super.onKeyDown(keyCode,event)
    }
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if(remoteVolumeKeys.remove(keyCode)) return true
        return super.onKeyUp(keyCode,event)
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent);mediaNavigation(intent) }

    override fun onStart() {
        super.onStart()
        if (::discovery.isInitialized) discovery.foreground()
        if (::pairing.isInitialized) pairing.foreground()
        if (::session.isInitialized) session.foreground(this)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        (application as AniCeApplication).clipboard.focus(hasFocus, this)
    }

    override fun onStop() {
        remoteVolumeKeys.clear()
        super.onStop()
        (application as AniCeApplication).clipboard.focus(false, this)
        if (!isChangingConfigurations && ::discovery.isInitialized) discovery.background()
        if (!isChangingConfigurations && ::pairing.isInitialized) pairing.background()
        if (::session.isInitialized) session.background(this, isChangingConfigurations)
    }
}
