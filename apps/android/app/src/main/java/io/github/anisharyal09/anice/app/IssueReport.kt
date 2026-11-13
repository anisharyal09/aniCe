// SPDX-License-Identifier: GPL-3.0-or-later
// Builds a user-reviewed GitHub issue link containing only app and OS versions.
package io.github.anisharyal09.anice.app

import java.net.URLEncoder

internal object IssueReport {
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
