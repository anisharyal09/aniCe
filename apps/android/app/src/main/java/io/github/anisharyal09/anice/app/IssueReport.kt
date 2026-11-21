// SPDX-License-Identifier: GPL-3.0-or-later
// Builds user-reviewed GitHub and email links without private diagnostics.
package io.github.anisharyal09.anice.app

import java.net.URLEncoder

internal object IssueReport {
    const val emailAddress = "anish.creations.hq@gmail.com"
    const val emailUrl = "mailto:$emailAddress?subject=%5BaniCe%5D%20Feedback%20%26%20Support"

    fun url(appVersion: String, osVersion: String): String {
        val fields = listOf(
            "template" to "bug_report.yml",
            "app-version" to appVersion,
            "os-version" to osVersion,
        )
        return "https://github.com/anisharyal09/aniCe/issues/new?" + fields.joinToString("&") {
            "${it.first}=${URLEncoder.encode(it.second, "UTF-8")}"
        }
    }
}
