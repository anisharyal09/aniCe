// SPDX-License-Identifier: GPL-3.0-or-later
// Fetches bounded GitHub release metadata with conditional requests and Atom fallback.
package io.github.anisharyal09.anice.update

import android.content.Context
import android.content.SharedPreferences
import android.util.Xml
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.xmlpull.v1.XmlPullParser
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import javax.net.ssl.HttpsURLConnection

internal data class ReleaseResponse(val status: Int, val body: String = "", val etag: String? = null)
internal fun interface ReleaseTransport {
    fun request(url: String, method: String, etag: String?): ReleaseResponse
}

internal class GithubReleaseTransport : ReleaseTransport {
    override fun request(url: String, method: String, etag: String?): ReleaseResponse {
        var target = URL(url)
        repeat(6) {
            require(target.protocol == "https" && target.userInfo == null && (target.port == -1 || target.port == 443) &&
                target.host.lowercase() in setOf("api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com")) { "Untrusted update URL" }
            val connection = (target.openConnection() as HttpsURLConnection).apply {
                requestMethod = method
                connectTimeout = 10_000
                readTimeout = 15_000
                instanceFollowRedirects = false
                setRequestProperty("Accept", "application/vnd.github+json")
                if (etag != null) setRequestProperty("If-None-Match", etag)
            }
            try {
                val status = connection.responseCode
                if (status in 300..399 && status != HttpURLConnection.HTTP_NOT_MODIFIED) {
                    val location = connection.getHeaderField("Location") ?: error("Missing redirect location")
                    target = URL(target, location)
                } else {
                    if (method == "HEAD" || status != HttpURLConnection.HTTP_OK) return ReleaseResponse(status)
                    require(connection.contentLengthLong <= 2_097_152) { "Release metadata is too large" }
                    val data = ByteArrayOutputStream()
                    connection.inputStream.use { input ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            require(data.size() + count <= 2_097_152) { "Release metadata is too large" }
                            data.write(buffer, 0, count)
                        }
                    }
                    return ReleaseResponse(status, data.toString(Charsets.UTF_8.name()), connection.getHeaderField("ETag"))
                }
            } finally { connection.disconnect() }
        }
        error("Too many update redirects")
    }
}

internal sealed interface DiscoveryResult {
    data class Available(val release: AvailableRelease) : DiscoveryResult
    data object UpToDate : DiscoveryResult
    data object Deferred : DiscoveryResult
    data class Failed(val message: String) : DiscoveryResult
}

internal class ReleaseDiscovery(private val preferences: SharedPreferences, private val transport: ReleaseTransport = GithubReleaseTransport()) {
    constructor(context: Context) : this(context.applicationContext.getSharedPreferences("update_preferences", Context.MODE_PRIVATE))
    var includeBeta: Boolean
        get() = preferences.getBoolean("include_beta", false)
        set(value) { preferences.edit().putBoolean("include_beta", value).apply() }
    fun skip(tag: String) { preferences.edit().putString("skipped_tag", tag).apply() }

    suspend fun check(current: UpdateVersion, force: Boolean = false, now: Long = System.currentTimeMillis()): DiscoveryResult = withContext(Dispatchers.IO) {
        val last = preferences.getLong("last_attempt", 0L)
        val failures = preferences.getInt("failures", 0).coerceIn(0, 7)
        val interval = if (failures == 0) 86_400_000L else (900_000L shl (failures - 1)).coerceAtMost(86_400_000L)
        if (!force && last > 0 && now >= last && now - last < interval) {
            val cached = try { cachedRelease(current) } catch (_: Exception) { null }
            return@withContext if (cached != null && cached.version.tag != preferences.getString("skipped_tag", null))
                DiscoveryResult.Available(cached) else DiscoveryResult.Deferred
        }
        preferences.edit().putLong("last_attempt", now).apply()
        try {
            val endpoint = "https://api.github.com/repos/anisharyal09/aniCe/releases?per_page=100"
            var response = transport.request(endpoint, "GET", preferences.getString("etag", null))
            if (response.status == HttpURLConnection.HTTP_NOT_MODIFIED && preferences.getString("cached_releases", null) == null) {
                preferences.edit().remove("etag").apply()
                response = transport.request(endpoint, "GET", null)
            }
            val release = when (response.status) {
                HttpURLConnection.HTTP_OK -> {
                    // Validate metadata before replacing the conditional-request cache.
                    val selected = ReleaseCatalog.fromJson(response.body, current, includeBeta)
                    preferences.edit().putString("cached_releases", response.body).putString("etag", response.etag).putString("last_source", "api").apply()
                    selected
                }
                HttpURLConnection.HTTP_NOT_MODIFIED -> {
                    val cached = preferences.getString("cached_releases", null) ?: error("Update cache missing")
                    ReleaseCatalog.fromJson(cached, current, includeBeta).also { preferences.edit().putString("last_source", "api").apply() }
                }
                HttpURLConnection.HTTP_FORBIDDEN, 429 -> fromAtom(current).also {
                    preferences.edit().putString("last_source", "atom").putString("atom_tag", it?.version?.tag).apply()
                }
                else -> error("GitHub returned HTTP ${response.status}")
            }
            preferences.edit().putInt("failures", 0).apply()
            if (release != null && release.version.tag != preferences.getString("skipped_tag", null)) DiscoveryResult.Available(release)
            else DiscoveryResult.UpToDate
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            preferences.edit().putInt("failures", (failures + 1).coerceAtMost(7)).apply()
            DiscoveryResult.Failed(error.message ?: "Unable to check for updates")
        }
    }

    private fun cachedRelease(current: UpdateVersion): AvailableRelease? {
        if (preferences.getString("last_source", null) == "api") {
            return preferences.getString("cached_releases", null)?.let { ReleaseCatalog.fromJson(it, current, includeBeta) }
        }
        val version = preferences.getString("atom_tag", null)?.let(UpdateVersion::parse) ?: return null
        if (version <= current || (!includeBeta && version.prerelease)) return null
        return AvailableRelease(version, "Release notes are available on GitHub.", ReleaseCatalog.assetUrl(version), null)
    }

    private fun fromAtom(current: UpdateVersion): AvailableRelease? {
        val response = transport.request("$RELEASE_ROOT.atom", "GET", null)
        check(response.status == HttpURLConnection.HTTP_OK) { "Update feed unavailable (HTTP ${response.status})" }
        require(!response.body.contains("<!DOCTYPE", ignoreCase = true) && !response.body.contains("<!ENTITY", ignoreCase = true) &&
            !response.body.contains('\u0000')) { "Unsupported update feed." }
        val parser = Xml.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
        parser.setInput(response.body.reader())
        val versions = mutableSetOf<UpdateVersion>()
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG && parser.name == "link") {
                val href = parser.getAttributeValue(null, "href").orEmpty()
                val prefix = "$RELEASE_ROOT/tag/"
                if (href.startsWith(prefix)) UpdateVersion.parse(href.removePrefix(prefix))?.let(versions::add)
            }
            event = parser.next()
        }
        for (version in versions.sortedDescending()) {
            if (version <= current || (!includeBeta && version.prerelease)) continue
            val asset = ReleaseCatalog.assetUrl(version)
            if (transport.request(asset, "HEAD", null).status == HttpURLConnection.HTTP_OK)
                return AvailableRelease(version, "Release notes are available on GitHub.", asset, null)
        }
        return null
    }
}
