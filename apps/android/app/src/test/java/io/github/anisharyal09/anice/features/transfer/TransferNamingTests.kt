// SPDX-License-Identifier: GPL-3.0-or-later
// Probes the shared non-overwriting destination-name rule for both receive paths.
package io.github.anisharyal09.anice.features.transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferNamingTests {
    @Test
    fun suffixZeroIsTheNameItselfAndTheRestIsPlacedBeforeTheExtension() {
        assertEquals("report.pdf", TransferNaming.suffixed("report.pdf", 0))
        assertEquals("report (1).pdf", TransferNaming.suffixed("report.pdf", 1))
        assertEquals("report (12).pdf", TransferNaming.suffixed("report.pdf", 12))
        // Only the last dot separates an extension, so a compound suffix keeps its own dots.
        assertEquals("archive.tar (4).gz", TransferNaming.suffixed("archive.tar.gz", 4))
        // Without an extension the suffix is appended to the whole name.
        assertEquals("README (3)", TransferNaming.suffixed("README", 3))
        // A leading dot names the file; it is not an extension separator.
        assertEquals(".gitignore (2)", TransferNaming.suffixed(".gitignore", 2))
        assertEquals("", TransferNaming.suffixed("", 0))
    }

    @Test
    fun noSuffixCanReproduceTheOriginalName() {
        val names = listOf("report.pdf", "README", ".gitignore", "archive.tar.gz", "a b (1).txt", "a (9).txt")
        for (name in names) {
            for (suffix in 1..64) {
                assertNotEquals(name, TransferNaming.suffixed(name, suffix))
            }
        }
        assertTrue(TransferNaming.MAXIMUM_SUFFIX > 64)
    }

    @Test
    fun theRuleIsClosedOverItsOwnOutput() {
        // Resolving a collision twice cannot produce a name that collides with either input.
        assertEquals("a (1) (1).txt", TransferNaming.suffixed(TransferNaming.suffixed("a.txt", 1), 1))
    }
}
