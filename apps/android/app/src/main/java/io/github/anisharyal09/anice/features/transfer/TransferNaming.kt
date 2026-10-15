// SPDX-License-Identifier: GPL-3.0-or-later
// Resolves the non-overwriting destination name shared by both receive publication paths.
package io.github.anisharyal09.anice.features.transfer

/**
 * Received files are never allowed to overwrite an existing file, and a completed, verified
 * transfer is never allowed to be discarded because its name was taken. Both receive paths resolve
 * that by suffixing, so the rule lives here rather than being restated per path.
 */
internal object TransferNaming {
    /** Bounds suffix search so a provider that always reports a name as taken cannot spin. */
    const val MAXIMUM_SUFFIX = 10000

    /**
     * [name] for suffix `0`, otherwise `base (suffix).ext`.
     * A leading dot is part of the name, not an extension separator, so `.part` keeps no extension.
     */
    fun suffixed(name: String, suffix: Int): String {
        if (suffix == 0) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        return "$base ($suffix)$ext"
    }
}
