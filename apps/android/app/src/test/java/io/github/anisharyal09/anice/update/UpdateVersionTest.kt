// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies release ordering and strict tag bounds.
package io.github.anisharyal09.anice.update

import org.junit.Assert.*
import org.junit.Test

class UpdateVersionTest {
    @Test fun ordersPrereleasesAndStable() {
        val tags = listOf("v0.4.0-alpha.1", "v0.4.0-alpha.19", "v0.4.0-beta.1", "v0.4.0-beta.19", "v0.4.0-rc.1", "v0.4.0-rc.19", "v0.4.0", "v0.4.1-alpha.1")
        val codes = tags.map { requireNotNull(UpdateVersion.parse(it)).code }
        assertEquals(codes.sorted().distinct(), codes)
        assertEquals(40021, UpdateVersion.parse("v0.4.0-beta.1")?.code)
        assertEquals(40099, UpdateVersion.parse("v0.4.0")?.code)
    }

    @Test fun rejectsAmbiguousAndOutOfRangeTags() {
        listOf("0.4.0", "v01.0.0", "v0.100.0", "v0.0.100", "v2001.0.0", "v0.0.1-beta.0", "v0.0.1-alpha.20", "v0.0.1-rc", "v0.0.1+build", "v0.0.1\n").forEach {
            assertNull(it, UpdateVersion.parse(it))
        }
    }
}
