// SPDX-License-Identifier: GPL-3.0-or-later
// Checks signing-certificate continuity before Android's final installer verification.
package io.github.anisharyal09.anice.update

import org.junit.Assert.*
import org.junit.Test

class UpdateSignerTest {
    private val a = byteArrayOf(1)
    private val b = byteArrayOf(2)
    private val c = byteArrayOf(3)
    @Test fun acceptsSameSignerAndForwardRotation() {
        assertTrue(compatibleSigningCertificates(false, listOf(a), false, listOf(a), listOf(a)))
        assertTrue(compatibleSigningCertificates(false, listOf(a), false, listOf(b), listOf(a, b)))
    }
    @Test fun rejectsUnrelatedOrReversedLineage() {
        assertFalse(compatibleSigningCertificates(false, listOf(a), false, listOf(b), listOf(b)))
        assertFalse(compatibleSigningCertificates(false, listOf(b), false, listOf(a), listOf(a)))
        assertFalse(compatibleSigningCertificates(false, listOf(a), false, listOf(b), listOf(b, a)))
        assertFalse(compatibleSigningCertificates(false, listOf(a), false, listOf(b), null))
    }
    @Test fun multipleSignersRequireTheExactSet() {
        assertTrue(compatibleSigningCertificates(true, listOf(a, b), true, listOf(b, a), null))
        assertFalse(compatibleSigningCertificates(true, listOf(a, b), true, listOf(a, c), null))
        assertFalse(compatibleSigningCertificates(true, listOf(a, b), false, listOf(a), listOf(a)))
        assertFalse(compatibleSigningCertificates(true, listOf(a, a), true, listOf(a, a), null))
    }
}
