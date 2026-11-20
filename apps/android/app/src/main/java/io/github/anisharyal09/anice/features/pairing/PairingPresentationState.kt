// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps observable pairing presentation injectable without exposing live authentication state mutation.
package io.github.anisharyal09.anice.features.pairing

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.anisharyal09.anice.infrastructure.pairing.PairingMethod

internal class PairingPresentationState {
    var method by mutableStateOf(PairingMethod.QR)
    var phase by mutableStateOf("idle")
    var status by mutableStateOf("Scan the QR code on your Mac, or enter its six-digit code.")
    var comparisonCode by mutableStateOf<String?>(null)
    var comparisonAttempt by mutableStateOf(0L)
    var completedWithComparison by mutableStateOf(false)
}

/** Pairing cleanup may finish after trust is saved; presentation cannot consume the locator early. */
internal class PairingCandidateHandoff<T>(private val discard: (T) -> Unit) {
    private var pending: T? = null
    fun offer(candidate: T) {
        clear()
        pending = candidate
    }
    fun take(phase: String): T? {
        if (phase != "paired") return null
        return pending.also { pending = null }
    }
    fun clear() {
        val previous = pending
        pending = null
        previous?.let(discard)
    }
}
