// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises channel selection and untrusted release asset validation.
package io.github.anisharyal09.anice.update

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ReleaseCatalogTest {
    private fun release(tag: String, pre: Boolean = false, asset: String = "aniCe-android.apk", size: Long = 50, draft: Boolean = false): JSONObject =
        JSONObject().put("tag_name", tag).put("draft", draft).put("prerelease", pre).put("body", "notes")
            .put("assets", JSONArray().put(JSONObject().put("name", asset).put("state", "uploaded").put("size", size)
                .put("browser_download_url", "$RELEASE_ROOT/download/$tag/$asset")))

    @Test fun stableAndBetaSelectionNeverDowngrades() {
        val data = JSONArray().put(release("v0.4.0-beta.2", true)).put(release("v0.3.1"))
        val current = requireNotNull(UpdateVersion.parse("v0.3.0"))
        assertEquals("v0.3.1", ReleaseCatalog.fromJson(data.toString(), current, false)?.version?.tag)
        assertEquals("v0.4.0-beta.2", ReleaseCatalog.fromJson(data.toString(), current, true)?.version?.tag)
        val beta = requireNotNull(UpdateVersion.parse("v0.4.0-beta.2"))
        assertNull(ReleaseCatalog.fromJson(data.toString(), beta, false))
        data.put(release("v0.4.0"))
        assertEquals("v0.4.0", ReleaseCatalog.fromJson(data.toString(), beta, false)?.version?.tag)
    }

    @Test fun rejectsInvalidAndUnpublishedAssets() {
        val current = requireNotNull(UpdateVersion.parse("v0.3.0"))
        for (item in listOf(release("v0.4.0", asset = "other.apk"), release("v0.4.0", size = 0),
            release("v0.4.0", size = MAX_UPDATE_BYTES + 1), release("v0.4.0", draft = true),
            release("v0.4.0-beta.1", pre = false), release("v0.4.0+bad"))) {
            assertNull(ReleaseCatalog.fromJson(JSONArray().put(item).toString(), current, true))
        }
        val item = release("v0.4.0")
        item.getJSONArray("assets").getJSONObject(0).put("browser_download_url", "https://example.com/aniCe-android.apk")
        assertNull(ReleaseCatalog.fromJson(JSONArray().put(item).toString(), current, true))
    }
}
