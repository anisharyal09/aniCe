// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.transfer

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import org.junit.Assert.*
import org.junit.Test

class SharedFileIntentTest {
    @Test fun acceptsSingleMultipleAndClipDataFiles() {
        val one = Uri.parse("content://example/one")
        val two = Uri.parse("content://example/two")
        assertEquals(listOf(one), sharedFileUris(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, one)))
        assertEquals(listOf(one, two), sharedFileUris(Intent(Intent.ACTION_SEND_MULTIPLE)
            .putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(one, two))))
        assertEquals(listOf(one), sharedFileUris(Intent(Intent.ACTION_SEND).apply {
            clipData = ClipData.newRawUri("File", one)
        }))
    }
    @Test fun rejectsTextUnsafeUrisAndOversizedBatches() {
        assertNull(sharedFileUris(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "hello")))
        assertNull(sharedFileUris(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, Uri.parse("file:///private/file"))))
        assertNull(sharedFileUris(Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(
            Intent.EXTRA_STREAM, ArrayList(List(129) { Uri.parse("content://example/$it") }))))
    }
}
