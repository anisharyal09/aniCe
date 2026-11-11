// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies that update downloads cannot redirect to untrusted origins.
package io.github.anisharyal09.anice.update

import java.net.URL
import org.junit.Assert.*
import org.junit.Test

class UpdateUrlTest {
    @Test fun onlyAllowsHttpsGithubAssetHosts() {
        assertTrue(trustedUpdateURL(URL("https://github.com/anisharyal09/aniCe/releases/download/v0.4.0/aniCe-android.apk")))
        assertTrue(trustedUpdateURL(URL("https://release-assets.githubusercontent.com/example")))
        assertFalse(trustedUpdateURL(URL("http://github.com/example")))
        assertFalse(trustedUpdateURL(URL("https://github.com.example.org/example")))
        assertFalse(trustedUpdateURL(URL("https://github.com@evil.example/example")))
        assertFalse(trustedUpdateURL(URL("https://github.com:444/example")))
    }
}
