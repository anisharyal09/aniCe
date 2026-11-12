<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Mac Desk Deck

Mac Desk Deck is an Android feature panel for a trusted Mac. It opens its shell immediately, then subscribes over the existing secured channel. It prefers an already-secured local-network channel and holds that channel steady for the panel session; Bluetooth is used when LAN is unavailable. Open **Features → Mac Desk Deck**, choose a paired Mac, and connect if needed.

## Status and recovery

The top card names the Mac, summarizes connection state and the local time of the last received sample, and gives each device a labeled power summary. **Details** shows transport, the full last-received date and time, thermal pressure and the keep-awake preference. A previous sample remains visible with its timestamp after reconnect or refresh, but controls remain disabled until a fresh sample arrives.

The panel shows opening progress immediately. After five seconds it explains that it is reconnecting once; after ten seconds it stops retrying and offers **Refresh**. Refresh starts a fresh read-only subscription and does not repeat any action. Readings become stale after three seconds without telemetry. The latest sample is cached locally so it can appear immediately after an app restart; cached readings are always stale and cannot enable actions until the Mac sends a fresh sample. The Mac stops sampling after fifteen seconds without a five-second renewal from the visible panel. Closing or backgrounding the panel sends Stop and cancels renewal.

## Meters and history

- **CPU** shows whole-system processor use from Mach host counters. The first sample can say “Collecting…” until the next counter reading establishes a baseline.
- **Memory used** shows physical memory minus free and cached memory against the physical total with Desk Deck v3. Details separate app, wired, compressed, other resident memory, cached files, free memory and swap. Cache is reclaimable and separate from used memory; swap uses disk space. Older Macs show **Memory (legacy)** with their category sum and an update explanation. Values are displayed in GiB.
- **Thermal pressure** shows macOS's nominal, fair, serious or critical state. It does not report sensor temperatures in degrees. See Apple's [thermal-state documentation](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum).
- CPU and memory history keeps the latest 60 points in memory. Disconnects create visible gaps; the app does not interpolate missing samples.
- The header shows Mac battery percentage, source and charging state, alongside the phone's own percentage and charging state. Unavailable and no-battery states remain explicit.

Meters refresh about once per second while subscribed. History clears when the selected trusted Mac changes or the app process exits.

## Quick controls and app shortcuts

- **Mute input** controls only the Mac's current default input, and only when Core Audio exposes a writable mute property. If unavailable, choose an input in Mac System Settings → Sound → Input; some devices have no software mute control. It is not a hardware kill switch and does not affect apps using another input.
- **Lock Mac** requests the public Control–Command–Q session-lock shortcut when Mac Event Posting permission is available. If it is missing, tap the tile for setup guidance; access is granted on the Mac.
- **Screenshot** opens the native macOS Screenshot controls. Choose an area, window or display, save locally, or cancel on the Mac. The phone confirms only that the controls opened; the image is not sent to the phone.
- **DND mode** runs the separate Mac-local toggle Shortcut selected in Mac Settings → Do Not Disturb → Desk Deck button. It does not sync the change to the phone. aniCe confirms only that the Shortcut ran; check Focus on the Mac to confirm the result.
- **Mac output volume** sets the current default output's absolute volume when macOS exposes a writable system control. A target change rejects stale writes; slider movement keeps only the latest queued value.
- **Output device** lists connected Mac audio outputs and shows the current default. Choosing one changes macOS's default output alongside the volume slider; apps with their own output selection may keep using it. Device changes refresh the list while the deck is open; a removed device or stale list is rejected and can be refreshed from the phone.
- The **Approved apps** grid shows apps explicitly allowed for that trusted phone in Mac Settings → Desk Deck. Pin and order shortcuts on the phone; Terminal and Blender are offered when installed. The Mac announces catalog changes to an open panel; the phone reloads pages for the new revision. The Mac resolves each opaque shortcut ID against its current approved bundle before launch.
- App approvals are tied to both the selected bundle and its executable file identity. Moving, replacing, or revoking the app invalidates the shortcut; reapprove a replacement in Settings → Desk Deck. Removing a phone's trust removes that phone's saved approvals.
- Brightness remains unsupported because macOS has no documented general display-brightness setter for this app; aniCe does not use private APIs or helper tools.

Every control has independent feedback. Actions require a fresh sample and are scoped to the current subscription. A request without a response is shown as unconfirmed and is never replayed automatically.

## Layout and screen behavior

Landscape presents meters and quick actions in an adaptive grid. Portrait stacks the same content naturally. Output selection sits with the volume control; the slider does not share a horizontal swipe-navigation surface. Text follows Android font scaling and controls retain touch targets of at least 48 dp.

Desk Deck stays within the regular Android app shell. The app bar Back button and bottom destinations remain available while the panel is open.

**Keep screen awake while charging** is off by default and uses the standard labeled checkbox control. When enabled, it prevents the screen timeout only while Desk Deck is visible and Android reports external power; backgrounding, unplugging, or leaving the panel restores the normal timeout.

## Implementation and protocol

V1 through v4 remain available for older Macs. V3 adds app, cache, free and swap readings with explicit unavailable values. V4 adds the selected Do Not Disturb Shortcut while retaining the v3 sample shape. V5 adds the Mac output picker using a bounded, revisioned catalog and opaque route IDs. V2 supplies power samples, renewable subscriptions, and paged approved-app catalogs. Device Power is a separate event-driven capability: each device can show its trusted peer's battery and charging status without opening Desk Deck. Neither capability opens a connection or extends another feature's lease.

See the [Desk Deck v1–v5 contract](../../protocol/desk-deck/README.md) and [Device Power v1 contract](../../protocol/device-power/README.md).
