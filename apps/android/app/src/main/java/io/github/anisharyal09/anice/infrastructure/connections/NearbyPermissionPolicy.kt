// SPDX-License-Identifier: GPL-3.0-or-later
// Requests first-pair discovery access once, never on background return or after a user denial.
package io.github.anisharyal09.anice.infrastructure.connections

internal fun initialNearbyPermissionReady(
    eligible: Boolean,
    missing: Boolean,
    requested: Boolean,
    previouslyDenied: Boolean,
): Boolean = eligible && missing && !requested && !previouslyDenied
