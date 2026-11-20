// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies saved release notices and conditional request behavior.
package io.github.anisharyal09.anice.update

import android.content.SharedPreferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.job
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.URL
import java.security.Principal
import java.security.cert.Certificate
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import javax.net.ssl.HttpsURLConnection

private class MetadataConnection(
    url: URL,
    private val response: Int,
    private val stream: InputStream = ByteArrayInputStream("[]".toByteArray()),
    private val beforeResponse: () -> Unit = {},
) : HttpsURLConnection(url) {
    var disconnected = false
    override fun connect() = Unit
    override fun disconnect() { disconnected = true }
    override fun usingProxy() = false
    override fun getResponseCode(): Int { beforeResponse(); return response }
    override fun getInputStream() = stream
    override fun getContentLengthLong() = -1L
    override fun getHeaderField(name: String?) =
        if (name == "Location") "https://api.github.com/redirected" else null
    override fun getCipherSuite() = "TLS_TEST"
    override fun getLocalCertificates(): Array<Certificate>? = null
    override fun getServerCertificates(): Array<Certificate> = emptyArray()
    override fun getPeerPrincipal(): Principal = Principal { "test" }
    override fun getLocalPrincipal(): Principal? = null
}

private class MemoryPreferences : SharedPreferences {
    val data = mutableMapOf<String, Any>()
    override fun getAll(): MutableMap<String, *> = data.toMutableMap()
    override fun getString(key: String?, defValue: String?): String? = data[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST") override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? = data[key] as? MutableSet<String> ?: defValues
    override fun getInt(key: String?, defValue: Int) = data[key] as? Int ?: defValue
    override fun getLong(key: String?, defValue: Long) = data[key] as? Long ?: defValue
    override fun getFloat(key: String?, defValue: Float) = data[key] as? Float ?: defValue
    override fun getBoolean(key: String?, defValue: Boolean) = data[key] as? Boolean ?: defValue
    override fun contains(key: String?) = data.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}
    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        override fun putString(key: String, value: String?): SharedPreferences.Editor = apply { if (value == null) data.remove(key) else data[key] = value }
        override fun putStringSet(key: String, value: MutableSet<String>?): SharedPreferences.Editor = apply { if (value == null) data.remove(key) else data[key] = value }
        override fun putInt(key: String, value: Int): SharedPreferences.Editor = apply { data[key] = value }
        override fun putLong(key: String, value: Long): SharedPreferences.Editor = apply { data[key] = value }
        override fun putFloat(key: String, value: Float): SharedPreferences.Editor = apply { data[key] = value }
        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = apply { data[key] = value }
        override fun remove(key: String): SharedPreferences.Editor = apply { data.remove(key) }
        override fun clear(): SharedPreferences.Editor = apply { data.clear() }
        override fun commit() = true
        override fun apply() {}
    }
}

class ReleaseDiscoveryTest {
    private val body = """[{"tag_name":"v0.4.0","draft":false,"prerelease":false,"body":"Notes","assets":[{"name":"aniCe-android.apk","state":"uploaded","size":50,"browser_download_url":"$RELEASE_ROOT/download/v0.4.0/aniCe-android.apk"}]}]"""
    private val current = requireNotNull(UpdateVersion.parse("v0.3.0"))

    @Test fun automaticChecksDefaultOnAndSavedOptOutBlocksRequestsButNotManualChecks() = runBlocking {
        val preferences = MemoryPreferences()
        var calls = 0
        val transport = ReleaseTransport { _, _, _ -> calls++; ReleaseResponse(200, body, "manual") }
        val discovery = ReleaseDiscovery(preferences, transport)
        assertTrue(discovery.automaticChecks)
        discovery.automaticChecks = false
        val restored = ReleaseDiscovery(preferences, transport)
        assertFalse(restored.automaticChecks)
        assertEquals(DiscoveryResult.Deferred, restored.check(current, now = 100))
        assertEquals(0, calls)
        assertFalse(preferences.contains("last_attempt"))
        assertFalse(preferences.contains("last_success"))
        assertTrue(restored.check(current, force = true, now = 101) is DiscoveryResult.Available)
        assertEquals(1, calls)
        restored.automaticChecks = true
        assertTrue(ReleaseDiscovery(preferences).automaticChecks)
        assertTrue(restored.check(current, now = 101 + UpdateSchedule.DAY) is DiscoveryResult.Available)
        assertEquals(2, calls)
    }

    @Test fun automaticOptOutKeepsCachedReviewSkipAndNotificationFloors() = runBlocking {
        val preferences = MemoryPreferences()
        val discovery = ReleaseDiscovery(preferences, ReleaseTransport { _, _, _ -> ReleaseResponse(200, body, "cached") })
        val release = (discovery.check(current, force = true, now = 100) as DiscoveryResult.Available).release
        discovery.markNotified(release)
        discovery.skip("v0.5.0")
        discovery.includeBeta = true
        discovery.automaticChecks = false
        assertEquals(release, discovery.cachedNotice(current))
        val newer = release.copy(version = requireNotNull(UpdateVersion.parse("v0.4.1")))
        assertFalse(discovery.shouldNotify(newer))
        discovery.automaticChecks = true
        val restored = ReleaseDiscovery(preferences)
        assertTrue(restored.includeBeta)
        assertFalse(restored.shouldNotify(release))
        assertTrue(restored.shouldNotify(newer))
        assertEquals("v0.5.0", preferences.getString("skipped_tag", null))
        assertEquals(100L, preferences.getLong("last_success", 0))
    }

    @Test fun cachesAndReusesETagAndNotice() = runBlocking {
        val preferences = MemoryPreferences()
        val calls = mutableListOf<String?>()
        val responses = ArrayDeque(listOf(ReleaseResponse(200, body, "tag1"), ReleaseResponse(304)))
        val discovery = ReleaseDiscovery(preferences, ReleaseTransport { _, _, etag -> calls.add(etag); responses.removeFirst() })
        assertTrue(discovery.check(current, true, 100) is DiscoveryResult.Available)
        assertTrue(discovery.check(current, false, 101) is DiscoveryResult.Available)
        assertTrue(discovery.check(current, true, 102) is DiscoveryResult.Available)
        assertEquals(listOf(null, "tag1"), calls)
        discovery.skip("v0.4.0")
        assertEquals(DiscoveryResult.Deferred, discovery.check(current, false, 103))
    }

    @Test fun missingCacheRetriesWithoutETag() = runBlocking {
        val preferences = MemoryPreferences().apply { data["etag"] = "orphan" }
        val calls = mutableListOf<String?>()
        val responses = ArrayDeque(listOf(ReleaseResponse(304), ReleaseResponse(200, body, "new")))
        val discovery = ReleaseDiscovery(preferences, ReleaseTransport { _, _, etag -> calls.add(etag); responses.removeFirst() })
        assertTrue(discovery.check(current, true, 100) is DiscoveryResult.Available)
        assertEquals(listOf("orphan", null), calls)
    }

    @Test fun failedChecksBackOffWithoutDiscardingLastGoodCache() = runBlocking {
        val preferences = MemoryPreferences()
        val responses = ArrayDeque(listOf(ReleaseResponse(200, body, "tag1"), ReleaseResponse(500)))
        val discovery = ReleaseDiscovery(preferences, ReleaseTransport { _, _, _ -> responses.removeFirst() })
        assertTrue(discovery.check(current, true, 100) is DiscoveryResult.Available)
        assertTrue(discovery.check(current, true, 200) is DiscoveryResult.Failed)
        assertTrue(discovery.check(current, false, 201) is DiscoveryResult.Available)
    }

    private fun time(value: String) = Instant.parse(value).toEpochMilli()

    @Test fun nepalDeadlineIsFixedAndMorningSuccessDoesNotSuppressEvening() = runBlocking {
        val morning = time("2026-11-14T07:00:00Z")
        val evening = time("2026-11-14T13:45:00Z")
        assertEquals(evening - UpdateSchedule.DAY, UpdateSchedule.latestEvening(evening - 1))
        assertEquals(evening, UpdateSchedule.latestEvening(evening))
        val preferences = MemoryPreferences()
        val calls = mutableListOf<String?>()
        val responses = ArrayDeque(listOf(ReleaseResponse(200, body, "tag1"), ReleaseResponse(304)))
        val discovery = ReleaseDiscovery(preferences, ReleaseTransport { _, _, etag -> calls.add(etag); responses.removeFirst() })
        assertTrue(discovery.check(current, true, morning) is DiscoveryResult.Available)
        assertEquals(evening, discovery.nextAutomaticCheck(morning + 1))
        assertTrue(discovery.check(current, false, evening - 1) is DiscoveryResult.Available)
        assertEquals(1, calls.size)
        assertTrue(discovery.check(current, false, evening) is DiscoveryResult.Available)
        assertEquals(listOf(null, "tag1"), calls)
        assertEquals(evening, preferences.getLong("last_success", 0))
        assertEquals(evening + UpdateSchedule.DAY, discovery.nextAutomaticCheck(evening + 1))
        assertTrue(discovery.check(current, false, evening + 1) is DiscoveryResult.Available)
        assertEquals(2, calls.size)
    }

    @Test fun failedEveningRemainsDueAndCanSucceedAnytimeAfterBackoff() = runBlocking {
        val evening = time("2026-11-14T13:45:00Z")
        val preferences = MemoryPreferences()
        var calls = 0
        val responses = ArrayDeque(listOf(ReleaseResponse(500), ReleaseResponse(200, body, "new")))
        val discovery = ReleaseDiscovery(preferences, ReleaseTransport { _, _, _ -> calls++; responses.removeFirst() })
        assertTrue(discovery.check(current, false, evening) is DiscoveryResult.Failed)
        assertEquals(0, preferences.getLong("last_success", 0))
        assertEquals(evening + 900_000, discovery.nextAutomaticCheck(evening + 1))
        assertEquals(DiscoveryResult.Deferred, discovery.check(current, false, evening + 899_999))
        assertEquals(1, calls)
        val later = evening + 3_600_000
        assertTrue(discovery.check(current, false, later) is DiscoveryResult.Available)
        assertEquals(2, calls)
        assertEquals(later, preferences.getLong("last_success", 0))
        assertEquals(evening + UpdateSchedule.DAY, discovery.nextAutomaticCheck(later))
    }

    @Test fun completedEmptyCacheRemainsUpToDateWithoutAnotherRequest() = runBlocking {
        val evening = time("2026-11-15T13:45:00Z")
        val preferences = MemoryPreferences()
        val responses = ArrayDeque(listOf(ReleaseResponse(200, "[]", "empty"), ReleaseResponse(500)))
        var calls = 0
        val discovery = ReleaseDiscovery(preferences, ReleaseTransport { _, _, _ -> calls++; responses.removeFirst() })
        assertEquals(DiscoveryResult.UpToDate, discovery.check(current, false, evening))
        assertEquals(DiscoveryResult.UpToDate, discovery.check(current, false, evening + 1))
        assertEquals(1, calls)
        assertTrue(discovery.check(current, true, evening + 2) is DiscoveryResult.Failed)
        assertEquals(DiscoveryResult.Deferred, discovery.check(current, false, evening + 3))
    }

    @Test fun missingAndInvalidCachesCannotClaimUpToDate() = runBlocking {
        val evening = time("2026-11-15T13:45:00Z")
        val preferences = MemoryPreferences().apply {
            data["last_success"] = evening
            data["last_attempt"] = evening
            data["last_source"] = "api"
        }
        val discovery = ReleaseDiscovery(preferences, ReleaseTransport { _, _, _ -> error("No request is due") })
        assertEquals(DiscoveryResult.Deferred, discovery.check(current, false, evening + 1))
        preferences.data["cached_releases"] = "invalid"
        assertEquals(DiscoveryResult.Deferred, discovery.check(current, false, evening + 2))
    }

    @Test fun overdueChecksAndClockRollbackDoNotWaitForAnotherEvening() {
        val now = time("2026-11-14T17:00:00Z")
        val evening = time("2026-11-14T13:45:00Z")
        assertEquals(now, UpdateSchedule.nextCheck(now, evening - 1, 0, 0))
        assertEquals(now, UpdateSchedule.nextCheck(now, now + UpdateSchedule.DAY, now + UpdateSchedule.DAY, 1))
        val delays = (1..7).map(UpdateSchedule::retryDelay)
        assertEquals(7, delays.size)
        assertTrue(delays.zipWithNext().all { (first, next) -> next > first })
        assertEquals(delays.last(), UpdateSchedule.retryDelay(100))
        assertEquals(0, UpdateSchedule.retryDelay(-1))
    }

    @Test fun notificationsArePersistentOncePerChannelVersionAndRespectBetaAndSkip() {
        fun release(tag: String) = AvailableRelease(requireNotNull(UpdateVersion.parse(tag)), "Notes",
            "$RELEASE_ROOT/download/$tag/aniCe-android.apk", 50)
        val stable = release("v0.3.1")
        val beta = release("v0.4.0-beta.2")
        val preferences = MemoryPreferences()
        val discovery = ReleaseDiscovery(preferences, ReleaseTransport { _, _, _ -> error("No network needed") })
        assertTrue(discovery.shouldNotify(stable))
        assertFalse(discovery.shouldNotify(beta))
        discovery.markNotified(stable)
        assertFalse(discovery.shouldNotify(stable))
        discovery.includeBeta = true
        assertTrue(discovery.shouldNotify(beta))
        discovery.markNotified(beta)
        discovery.includeBeta = false
        assertTrue(discovery.shouldNotify(release("v0.3.2")))
        assertFalse(discovery.shouldNotify(beta))
        discovery.includeBeta = true
        assertFalse(discovery.shouldNotify(beta))
        val restored = ReleaseDiscovery(preferences)
        assertFalse(restored.shouldNotify(beta))
        assertFalse(restored.shouldNotify(stable))
        discovery.markNotified(release("v0.4.0"))
        assertFalse(discovery.shouldNotify(release("v0.3.2")))
        discovery.skip("v0.5.0")
        assertFalse(discovery.shouldNotify(release("v0.5.0")))
    }

    @Test fun cancelledMetadataDoesNotReplaceTheCacheOrCompleteTheEvening() = runBlocking {
        val started = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val evening = time("2026-11-15T13:45:00Z")
        val preferences = MemoryPreferences()
        val discovery = ReleaseDiscovery(preferences, ReleaseTransport { _, _, _ ->
            started.countDown()
            check(resume.await(5, TimeUnit.SECONDS))
            ReleaseResponse(200, body, "cancelled")
        })
        val job = launch(Dispatchers.Default) {
            discovery.check(current, true, evening)
        }
        try {
            assertTrue(started.await(5, TimeUnit.SECONDS))
            job.cancel()
        } finally {
            resume.countDown()
            job.join()
        }
        assertFalse(preferences.contains("cached_releases"))
        assertFalse(preferences.contains("last_success"))
        assertFalse(preferences.contains("etag"))
        val later = evening + 60_000
        assertEquals(later, discovery.nextAutomaticCheck(later))
        assertEquals(later, ReleaseDiscovery(preferences).nextAutomaticCheck(later))
    }

    @Test fun cancelledRedirectCannotOpenAnotherMetadataConnection() = runBlocking {
        val url = URL("https://api.github.com/repos/anisharyal09/aniCe/releases")
        lateinit var connection: MetadataConnection
        var opens = 0
        val request = launch {
            val owner = currentCoroutineContext().job
            connection = MetadataConnection(url, 302, beforeResponse = { owner.cancel() })
            GithubReleaseTransport { opens++; connection }.request(url.toString(), "GET", null)
        }
        request.join()
        assertTrue(request.isCancelled)
        assertEquals(1, opens)
        assertTrue(connection.disconnected)
    }

    @Test fun cancelledBodyStopsReadingAndDisconnectsWithoutSavingMetadata() = runBlocking {
        val url = URL("https://api.github.com/repos/anisharyal09/aniCe/releases")
        val preferences = MemoryPreferences()
        lateinit var connection: MetadataConnection
        var reads = 0
        var closed = false
        val request = launch {
            val owner = currentCoroutineContext().job
            val stream = object : InputStream() {
                override fun read() = error("Use bounded buffer reads")
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    reads++
                    owner.cancel()
                    buffer[offset] = '['.code.toByte()
                    return 1
                }
                override fun close() { closed = true }
            }
            connection = MetadataConnection(url, 200, stream)
            ReleaseDiscovery(preferences, GithubReleaseTransport { connection }).check(current)
        }
        request.join()
        assertTrue(request.isCancelled)
        assertEquals(1, reads)
        assertTrue(closed)
        assertTrue(connection.disconnected)
        assertFalse(preferences.contains("cached_releases"))
        assertFalse(preferences.contains("last_success"))
        assertFalse(preferences.contains("failures"))
    }

    @Test fun cancelledNetworkFailureDoesNotIncrementBackoff() = runBlocking {
        val preferences = MemoryPreferences()
        val request = launch {
            val owner = currentCoroutineContext().job
            ReleaseDiscovery(preferences, ReleaseTransport { _, _, _ ->
                owner.cancel()
                throw java.io.IOException("Cancelled socket closed")
            }).check(current)
        }
        request.join()
        assertTrue(request.isCancelled)
        assertFalse(preferences.contains("failures"))
        assertFalse(preferences.contains("last_success"))
    }
}
