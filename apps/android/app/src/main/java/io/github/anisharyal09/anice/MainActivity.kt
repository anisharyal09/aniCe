// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import io.github.anisharyal09.anice.app.AppRoot
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityViewModel
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import io.github.anisharyal09.anice.features.discovery.DiscoveryViewModel

class MainActivity : ComponentActivity() {
    private lateinit var discovery: DiscoveryViewModel
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val service = (application as AniCeApplication).identityService
        // The activity hosts UI; its lifecycle ViewModel retains identity state during recreation.
        val factory = viewModelFactory { initializer { DeviceIdentityViewModel(service) } }
        val identity = ViewModelProvider(this, factory)[DeviceIdentityViewModel::class.java]
        val discoveryFactory = viewModelFactory { initializer { DiscoveryViewModel(application) } }
        discovery = ViewModelProvider(this, discoveryFactory)[DiscoveryViewModel::class.java]
        setContent { AniCeTheme { AppRoot(identity, discovery) } }
    }
    override fun onStart() {
        super.onStart()
        if (::discovery.isInitialized) discovery.foreground()
    }
    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations && ::discovery.isInitialized) discovery.background()
    }
}
