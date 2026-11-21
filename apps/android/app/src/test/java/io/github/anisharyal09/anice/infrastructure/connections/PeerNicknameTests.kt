// SPDX-License-Identifier: GPL-3.0-or-later
// Checks nickname validation without treating display metadata as identity.
package io.github.anisharyal09.anice.infrastructure.connections

import org.junit.Assert.*
import org.junit.Test

class PeerNicknameTests {
    @Test fun acceptsDisabledEmptyNickname() { assertEquals("", PeerNickname("", false).name) }
    @Test fun enabledRequiresName() {
        assertThrows(IllegalArgumentException::class.java) { PeerNickname("", true) }
    }
    @Test fun boundsUnicodeByCodePoints() {
        assertEquals(64, PeerNickname("😀".repeat(64), true).name.codePointCount(0, 128))
        assertThrows(IllegalArgumentException::class.java) { PeerNickname("😀".repeat(65), true) }
    }
    @Test fun rejectsUntrimmedName() {
        assertThrows(IllegalArgumentException::class.java) { PeerNickname(" nickname ", true) }
    }
}
