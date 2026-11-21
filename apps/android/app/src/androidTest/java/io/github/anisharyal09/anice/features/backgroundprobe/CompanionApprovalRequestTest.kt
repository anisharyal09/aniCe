// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies every enrollment uses one authenticated native address, no broad chooser or extra feature profile.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.companion.BluetoothLeDeviceFilter
import android.bluetooth.le.ScanFilter
import android.os.ParcelUuid
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import io.github.anisharyal09.anice.infrastructure.bluetooth.BlePayloadCodec
import io.github.anisharyal09.anice.infrastructure.connections.CompanionSetupTarget
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 31)
class CompanionApprovalRequestTest {
    @Test fun enrollmentAlwaysUsesSingleDeviceApprovalForThePinnedMac() {
        val peer = DeviceIdentity("fixture", "Verified Mac", "macos", "key", "fingerprint")
        for (address in listOf("02:00:00:00:00:01", "02:00:00:00:00:02")) {
            val target = CompanionSetupTarget(peer, address, "secured-channel", 60_000)
            val request = companionApprovalRequest(target)
            assertTrue(request.isSingleDevice)
            val expected = BluetoothLeDeviceFilter.Builder().setScanFilter(ScanFilter.Builder()
                .setDeviceAddress(address)
                .setServiceUuid(ParcelUuid(UUID.fromString(BlePayloadCodec.SERVICE_UUID))).build()).build()
            // AssociationRequest equality includes creation time; compare the actual device filter independently.
            assertEquals("Only the authenticated Mac may be selected", expected, companionApprovalFilter(target))
            assertNotEquals(companionApprovalFilter(target),
                companionApprovalFilter(target.copy(address = "02:00:00:00:00:03")))
            assertNull("Reconnection must not request a call/message-specific device role", request.deviceProfile)
            assertFalse(request.isSelfManaged)
        }
    }
}
