// SPDX-License-Identifier: GPL-3.0-or-later
// Counts job-scoped work only under eligible native owners, independently of transport and cryptographic generations.
package io.github.anisharyal09.anice.infrastructure.connections

// The registry monitor serializes producer releases; the connection owner dispatches policy callbacks on Main.
internal class ConnectionWorkLeases(private val changed: () -> Unit) {
    private val owners = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Any, Boolean>())
    private val jobs = mutableMapOf<java.util.UUID, Any>()
    val count get() = synchronized(this) { jobs.size }
    val held get() = synchronized(this) { jobs.isNotEmpty() }

    inner class Lease internal constructor(private val id: java.util.UUID, val tag: String) : AutoCloseable {
        override fun close() { release(id) }
    }

    @Synchronized private fun release(id: java.util.UUID) { if (jobs.remove(id) != null) changed() }

    @Synchronized
    fun updateOwner(owner: Any, eligible: Boolean) {
        if (eligible) owners.add(owner) else {
            owners.remove(owner)
            val removed = jobs.entries.removeAll { it.value === owner }
            if (removed) changed()
        }
    }

    @Synchronized fun acquire(owner: Any, tag: String): Lease {
        check(owner in owners) { "An eligible native work owner is required" }
        require(tag.isNotEmpty() && tag.length <= 64)
        check(jobs.size < 128) { "Too many active work leases" }
        val id = java.util.UUID.randomUUID()
        jobs[id] = owner
        changed()
        return Lease(id, tag)
    }

    @Synchronized fun clear() {
        val hadWork = held
        jobs.clear(); owners.clear()
        if (hadWork) changed()
    }
}
