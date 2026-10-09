// SPDX-License-Identifier: GPL-3.0-or-later
// Transfers system companion binding and presence callbacks to the shared connection owner.
@file:Suppress("DEPRECATION", "OVERRIDE_DEPRECATION") // Android 12–15 deliver the older presence callbacks.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.companion.AssociationInfo
import android.companion.CompanionDeviceService
import android.companion.DevicePresenceEvent
import android.content.Intent
import android.os.Build
import androidx.annotation.RequiresApi

/** Service receiving system companion device presence events (API 31+). */
@RequiresApi(31)
class CompanionProbeService : CompanionDeviceService() {
  private val presence = ProbePresence()
  private var association: String? = null
  private val probe get() = CompanionProbe.get(this)
  override fun onCreate() {
    super.onCreate()
    // Only CDM creates this service in aniCe; rebinding after process death may omit presence replay.
    // The native binding owns execution, while every attempt still validates association and pinned trust.
    presence.bind()
    if (Build.VERSION.SDK_INT < 36) presence.event(2, false) // Older APIs expose only BLE presence.
    association = "${probe.associationId}/${probe.address}"
    probe.appeared(this)
  }
  override fun onDeviceAppeared(address: String) {
    if (Build.VERSION.SDK_INT < 33 && address == probe.address) changed(1, true)
  }
  override fun onDeviceDisappeared(address: String) {
    if (Build.VERSION.SDK_INT < 33 && address == probe.address) changed(1, false)
  }
  override fun onDeviceAppeared(associationInfo: AssociationInfo) {
    if (Build.VERSION.SDK_INT in 33..35 && associationInfo.id == probe.associationId) changed(1, true)
  }
  override fun onDeviceDisappeared(associationInfo: AssociationInfo) {
    if (Build.VERSION.SDK_INT in 33..35 && associationInfo.id == probe.associationId) changed(1, false)
  }
  @RequiresApi(36)
  override fun onDevicePresenceEvent(event: DevicePresenceEvent) {
    // Callbacks for a removed/replaced association cannot claim the current probe's ownership.
    if (event.associationId != probe.associationId) return
    when (event.event) {
      DevicePresenceEvent.EVENT_BLE_APPEARED -> changed(1, true)
      DevicePresenceEvent.EVENT_BLE_DISAPPEARED -> changed(1, false)
      DevicePresenceEvent.EVENT_BT_CONNECTED -> changed(2, true)
      DevicePresenceEvent.EVENT_BT_DISCONNECTED -> changed(2, false)
    }
  }
  private fun changed(source: Int, appeared: Boolean) {
    val current = "${probe.associationId}/${probe.address}"
    if (association != current) {
      presence.bind()
      if (Build.VERSION.SDK_INT < 36) presence.event(2, false)
      association = current
    }
    // Duplicate native presence must reacquire a resumed policy's lease; the manager coalesces work.
    // Track facts even while paused so resume cannot depend on an OS callback being replayed.
    if (presence.event(source, appeared)) probe.appeared(this) else probe.disappeared(this)
  }
  override fun onUnbind(intent: Intent): Boolean {
    probe.disappeared(this)
    // The platform can bind this same service instance again; clear sources without permanently retiring it.
    presence.clear()
    return super.onUnbind(intent)
  }
  override fun onDestroy() {
    presence.retire()
    probe.disappeared(this)
    super.onDestroy()
  }
}
