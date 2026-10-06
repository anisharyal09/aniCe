// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice

import android.app.Application
import android.os.Build
import io.github.anisharyal09.anice.infrastructure.identity.AndroidIdentityKeys
import io.github.anisharyal09.anice.infrastructure.identity.AndroidIdentityMetadata
import io.github.anisharyal09.anice.infrastructure.identity.IdentityService

class AniCeApplication : Application() {
    // Share one service across activity recreation so identity operations stay serialized.
    val identityService by lazy { IdentityService(AndroidIdentityMetadata(this), AndroidIdentityKeys(), { Build.MODEL }) }
}
