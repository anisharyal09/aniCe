// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.deviceidentity

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import io.github.anisharyal09.anice.infrastructure.identity.IdentityErrorKind
import io.github.anisharyal09.anice.infrastructure.identity.IdentityException
import io.github.anisharyal09.anice.infrastructure.identity.IdentityService
import io.github.anisharyal09.anice.infrastructure.identity.IdentitySnapshot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class DeviceIdentityUiState(
    val snapshot: IdentitySnapshot? = null,
    val failure: IdentityErrorKind? = null,
    val isWorking: Boolean = false,
) {
    val canReset: Boolean
        get() = snapshot != null || failure == IdentityErrorKind.KEY_MISSING ||
            failure == IdentityErrorKind.INCONSISTENT || failure == IdentityErrorKind.CRYPTO_FAILURE
}

class DeviceIdentityViewModel(private val service: IdentityService) : ViewModel() {
    var state by mutableStateOf(DeviceIdentityUiState())
        private set

    init { retry() }

    fun retry() = update(reset = false)

    fun reset() {
        if (state.canReset) update(reset = true)
    }

    private fun update(reset: Boolean) {
        if (state.isWorking) return
        state = DeviceIdentityUiState(isWorking = true)
        viewModelScope.launch {
            state = try {
                // Keystore and disk access must not block the UI thread.
                val snapshot = withContext(Dispatchers.IO) {
                    if (reset) service.resetIdentity() else service.getOrCreateIdentity()
                }
                DeviceIdentityUiState(snapshot = snapshot)
            } catch (error: IdentityException) {
                DeviceIdentityUiState(failure = error.kind)
            }
        }
    }
}
