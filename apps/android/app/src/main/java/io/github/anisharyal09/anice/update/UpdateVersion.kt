// SPDX-License-Identifier: GPL-3.0-or-later
// Validates release tags and gives stable ordering to prereleases and releases.
package io.github.anisharyal09.anice.update

internal data class UpdateVersion(val tag: String, val code: Int, val prerelease: Boolean) : Comparable<UpdateVersion> {
    override fun compareTo(other: UpdateVersion): Int = code.compareTo(other.code)

    companion object {
        private val pattern = Regex("v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-(alpha|beta|rc)\\.([1-9][0-9]*))?")

        fun parse(tag: String): UpdateVersion? {
            val match = pattern.matchEntire(tag) ?: return null
            val major = match.groupValues[1].toIntOrNull() ?: return null
            val minor = match.groupValues[2].toIntOrNull() ?: return null
            val patch = match.groupValues[3].toIntOrNull() ?: return null
            val stage = match.groupValues[4]
            val number = if (stage.isEmpty()) 0 else match.groupValues[5].toIntOrNull() ?: return null
            if (major > 2000 || minor > 99 || patch > 99 || (stage.isNotEmpty() && number !in 1..19)) return null
            val stageCode = when (stage) {
                "alpha" -> number
                "beta" -> 20 + number
                "rc" -> 40 + number
                else -> 99
            }
            return UpdateVersion(tag, major * 1_000_000 + minor * 10_000 + patch * 100 + stageCode, stage.isNotEmpty())
        }
    }
}
