// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises journal backup recovery and failures before and after the atomic commit.
package io.github.anisharyal09.anice.infrastructure.storage

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AtomicJournalTest {
    @get:Rule val directory = TemporaryFolder()
    private val file get() = File(directory.root, "journal.json")
    private fun journal() = AtomicJournal(file, syncDirectory = {})

    @Test fun missingBaseRecoversBackupAndNeverReadsUncommittedTemporary() {
        File(file.path + ".bak").writeText("committed")
        File(file.path + ".new").writeText("unfinished")
        assertEquals("committed", journal().read()!!.toString(Charsets.UTF_8))
        assertFalse(File(file.path + ".bak").exists())
        journal().write("next".toByteArray())
        assertEquals("next", journal().read()!!.toString(Charsets.UTF_8))
        assertFalse(File(file.path + ".new").exists())
    }

    @Test fun backupSupersedesInterruptedOrCorruptBase() {
        file.writeText("unfinished")
        File(file.path + ".bak").writeText("committed")
        assertEquals("committed", journal().read()!!.toString(Charsets.UTF_8))
    }

    @Test fun firstRunDoesNotPromoteUncommittedTemporary() {
        assertNull(journal().read())
        File(file.path + ".new").writeText("unfinished")
        assertNull(journal().read())
        journal().write(byteArrayOf())
        assertArrayEquals(byteArrayOf(), journal().read())
    }

    @Test fun failedFileSyncPreservesCommittedBytesEvenForIdenticalReplacement() {
        file.writeText("committed")
        val faulty = AtomicJournal(file, syncFile = { throw IOException("sync failed") }, syncDirectory = {})
        for (bytes in listOf("next", "committed")) {
            assertThrows(IOException::class.java) { faulty.write(bytes.toByteArray()) }
            assertEquals("committed", journal().read()!!.toString(Charsets.UTF_8))
            assertFalse(File(file.path + ".new").exists())
        }
    }

    @Test fun failedAtomicMoveDoesNotDeleteDestinationOrLeaveTemporary() {
        assertTrue(file.mkdir())
        val marker = File(file, "keep").apply { writeText("owned elsewhere") }
        assertThrows(IOException::class.java) { journal().write("next".toByteArray()) }
        assertEquals("owned elsewhere", marker.readText())
        assertFalse(File(file.path + ".new").exists())
    }

    @Test fun failedBackupRecoveryFailsClosedAndPreservesBackup() {
        assertTrue(file.mkdir())
        File(file, "keep").writeText("owned elsewhere")
        val backup = File(file.path + ".bak").apply { writeText("committed") }
        assertThrows(IOException::class.java) { journal().read() }
        assertThrows(IOException::class.java) { journal().write("next".toByteArray()) }
        assertEquals("committed", backup.readText())
    }

    @Test fun directorySyncFailureIsReportedAfterCommitWithoutDestroyingCommittedBytes() {
        file.writeText("previous")
        val faulty = AtomicJournal(file, syncDirectory = { throw IOException("directory sync failed") })
        assertThrows(IOException::class.java) { faulty.write("next".toByteArray()) }
        assertEquals("next", journal().read()!!.toString(Charsets.UTF_8))
        assertFalse(File(file.path + ".new").exists())
    }

    @Test fun permissionRevocationPreservesCommittedBytes() {
        file.writeText("committed")
        val original = Files.getPosixFilePermissions(directory.root.toPath())
        try {
            Files.setPosixFilePermissions(directory.root.toPath(),
                java.nio.file.attribute.PosixFilePermissions.fromString("r-x------"))
            assertThrows(IOException::class.java) { journal().write("next".toByteArray()) }
            assertEquals("committed", file.readText())
        } finally { Files.setPosixFilePermissions(directory.root.toPath(), original) }
    }

    @Test fun quarantineRetainsAllJournalArtifactsWithoutTouchingOtherFiles() {
        val sources = listOf(file, File(file.path + ".bak"), File(file.path + ".new"))
        sources.forEachIndexed { index, source -> source.writeText("record-$index") }
        val unrelated = File(directory.root, "other").apply { writeText("keep") }
        journal().quarantine()
        assertTrue(sources.none { it.exists() })
        assertEquals(setOf("record-0", "record-1", "record-2"),
            directory.root.listFiles()!!.filter { ".quarantined-" in it.name }.map { it.readText() }.toSet())
        assertEquals("keep", unrelated.readText())
    }
}
