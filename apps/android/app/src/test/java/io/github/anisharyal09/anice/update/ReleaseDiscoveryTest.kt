// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies saved release notices and conditional request behavior.
package io.github.anisharyal09.anice.update

import android.content.SharedPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

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
}
