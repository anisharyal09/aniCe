// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies report links encode version fields without adding private data or changing the destination.
package io.github.anisharyal09.anice.app

import java.net.URI
import java.net.URLDecoder
import org.junit.Assert.*
import org.junit.Test

class IssueReportTest {
    @Test fun versionFieldsAreEncodedAndAreTheOnlyPrefilledInformation() {
        val cases = listOf(
            "0.9.0-beta.1" to "Android 16 (API 36)",
            "build + preview & test#1" to "Android 16 / नमस्ते",
            "v1\n&title=other&body=private" to "https://other.invalid/#redirect",
        )
        assertEquals(3, cases.size)
        for ((version, system) in cases) {
            val url = URI(IssueReport.url(version, system))
            assertEquals("https", url.scheme)
            assertEquals("github.com", url.host)
            assertEquals("/anisharyal09/aniCe/issues/new", url.path)
            assertNull(url.fragment)
            assertNull(url.userInfo)
            val fields = url.rawQuery.split("&").associate {
                val pair = it.split("=", limit = 2)
                pair[0] to URLDecoder.decode(pair[1], "UTF-8")
            }
            assertEquals(setOf("template", "app-version", "os-version"), fields.keys)
            assertEquals("bug_report.yml", fields["template"])
            assertEquals(version, fields["app-version"])
            assertEquals(system, fields["os-version"])
        }
    }
}
