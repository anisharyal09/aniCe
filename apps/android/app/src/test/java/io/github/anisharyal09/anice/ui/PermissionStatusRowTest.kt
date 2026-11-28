// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies granted permission visibility is confined to the dedicated Permissions category.
package io.github.anisharyal09.anice.ui

import io.github.anisharyal09.anice.features.notifications.NotificationPermissionSnapshot
import org.junit.Assert.*
import org.junit.Test

class PermissionStatusRowTest {
    @Test fun onlyMissingAccessIsVisibleOutsidePermissions() {
        for (allowed in listOf(false, true)) {
            for (showGranted in listOf(false, true)) {
                assertEquals(!allowed || showGranted, permissionRowVisible(allowed, showGranted))
            }
        }
    }

    @Test fun partialPhoneAndCallerIdentityGrantsRemainIndependent() {
        var combinations = 0
        for (notification in listOf(false, true)) {
            for (phone in listOf(false, true)) {
                for (answer in listOf(false, true)) {
                    for (log in listOf(false, true)) {
                        for (contacts in listOf(false, true)) {
                            val state = NotificationPermissionSnapshot(notification, phone, answer, log, contacts)
                            assertEquals(phone && answer, state.phoneAccess)
                            assertEquals(log && contacts, state.callerIdAccess)
                            assertEquals(notification && phone && answer && log && contacts, state.allAllowed)
                            combinations++
                        }
                    }
                }
            }
        }
        assertEquals(32, combinations)
    }
}
