// SPDX-License-Identifier: GPL-3.0-or-later
// Selects a valid, newer Android release from untrusted GitHub metadata.
package io.github.anisharyal09.anice.update

import org.json.JSONArray

internal const val MAX_UPDATE_BYTES = 256L * 1024 * 1024
internal const val RELEASE_ROOT = "https://github.com/anisharyal09/aniCe/releases"

internal data class AvailableRelease(
    val version: UpdateVersion,
    val notes: String,
    val assetUrl: String,
    val assetBytes: Long?,
) {
    val pageUrl: String get() = "$RELEASE_ROOT/tag/${version.tag}"
}

internal object ReleaseCatalog {
    fun assetUrl(version: UpdateVersion): String = "$RELEASE_ROOT/download/${version.tag}/aniCe-android.apk"

    fun fromJson(body: String, current: UpdateVersion, includeBeta: Boolean): AvailableRelease? {
        val releases = JSONArray(body)
        return (0 until releases.length()).mapNotNull { index ->
            val item = releases.optJSONObject(index) ?: return@mapNotNull null
            if (item.optBoolean("draft", true)) return@mapNotNull null
            val version = UpdateVersion.parse(item.optString("tag_name")) ?: return@mapNotNull null
            if (version <= current || (!includeBeta && version.prerelease) ||
                item.optBoolean("prerelease", !version.prerelease) != version.prerelease) return@mapNotNull null
            val assets = item.optJSONArray("assets") ?: return@mapNotNull null
            val asset = (0 until assets.length()).asSequence().mapNotNull(assets::optJSONObject)
                .firstOrNull { it.optString("name") == "aniCe-android.apk" && it.optString("state") == "uploaded" }
                ?: return@mapNotNull null
            val size = asset.optLong("size", -1)
            val url = asset.optString("browser_download_url")
            if (size !in 1..MAX_UPDATE_BYTES || url != assetUrl(version)) return@mapNotNull null
            AvailableRelease(version, item.optString("body", "").take(32_768), url, size)
        }.maxByOrNull { it.version }
    }
}
