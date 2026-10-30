// SPDX-License-Identifier: GPL-3.0-or-later
// Marshals temporary PIN-pairing arguments through the Rust JNI bridge.
package io.github.anisharyal09.anice.infrastructure.pairing
object NativePake {
    private val available =
        try {
            System.loadLibrary("anice_pairing")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }

    @JvmStatic external fun call(op: Int, input: ByteArray): ByteArray

    fun invoke(op: Int, vararg fields: ByteArray): ByteArray {
        check(available) { "PIN pairing library unavailable" }
        val input = PairingCodec.fields(*fields)
        try {
            return call(op, input)
        } finally {
            input.fill(0)
        }
    }
}
