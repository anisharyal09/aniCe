// SPDX-License-Identifier: GPL-3.0-or-later
// Pins Android and Compose plugin versions for the application build.
plugins {
    id("com.android.application") version "9.2.1" apply false
    // 2.4.20 fixes unsafe build-cache metadata deserialization (CVE-2026-53914).
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.20" apply false
}
