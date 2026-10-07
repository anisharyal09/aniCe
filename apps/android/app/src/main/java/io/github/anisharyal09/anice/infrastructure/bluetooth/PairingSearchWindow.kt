// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.bluetooth

/** A QR rendezvous search owns one deadline across candidate connections and resumed scans. */
internal class PairingSearchWindow<T>(private val now: () -> Long) {
    var deadline = 0L
        private set

    private val visited = linkedSetOf<T>()

    fun begin() {
        clear()
        deadline = now() + 15000
    }

    fun claim(candidate: T): Boolean = canContinue() && visited.add(candidate)

    fun canContinue(): Boolean = now() < deadline && visited.size < 32

    fun clear() {
        visited.clear()
        deadline = 0
    }
}
