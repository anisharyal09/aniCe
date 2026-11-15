// SPDX-License-Identifier: GPL-3.0-or-later
// Commits private journals with checked file/directory sync and recovers legacy AtomicFile backups.
package io.github.anisharyal09.anice.infrastructure.storage

import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING

internal class AtomicJournal(
    private val file: File,
    private val syncFile: (FileOutputStream) -> Unit = { it.fd.sync() },
    private val syncDirectory: (File) -> Unit = {
        val fd = Os.open(it.path, OsConstants.O_RDONLY or OsConstants.O_CLOEXEC, 0)
        try { Os.fsync(fd) } finally { Os.close(fd) }
    },
) {
    private val backup = File(file.path + ".bak")
    private val temporary = File(file.path + ".new")

    private fun recoverBackup() {
        if (backup.exists()) {
            Files.move(backup.toPath(), file.toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
            syncDirectory(file.absoluteFile.parentFile!!)
        }
    }

    fun read(): ByteArray? {
        recoverBackup()
        return try { Files.readAllBytes(file.toPath()) } catch (_: NoSuchFileException) { null }
    }

    fun write(bytes: ByteArray) {
        val directory = file.absoluteFile.parentFile!!
        Files.createDirectories(directory.toPath())
        recoverBackup()
        try {
            FileOutputStream(temporary).use { stream ->
                stream.write(bytes)
                syncFile(stream)
            }
            Files.move(temporary.toPath(), file.toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
            syncDirectory(directory)
        } catch (error: Exception) {
            try { Files.deleteIfExists(temporary.toPath()) }
            catch (cleanup: Exception) { error.addSuppressed(cleanup) }
            throw error
        }
    }

    fun quarantine() {
        val suffix = ".quarantined-" + java.util.UUID.randomUUID()
        for (source in listOf(file, backup, temporary)) {
            if (source.exists()) {
                Files.move(source.toPath(), File(source.path + suffix).toPath(), ATOMIC_MOVE)
                syncDirectory(file.absoluteFile.parentFile!!)
            }
        }
    }
}
