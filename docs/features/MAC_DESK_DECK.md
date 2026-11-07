<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Mac Desk Deck

Mac Desk Deck is an Android feature panel for a trusted Mac. It opens its shell immediately, then subscribes over the existing secured channel. It prefers an already-secured local-network channel and holds that channel steady for the panel session; Bluetooth is used when LAN is unavailable. Open **Features → Mac Desk Deck**, choose a paired Mac, and connect if needed.

## Status and recovery

The header names the Mac and shows its transport, connection, last sample age, and both devices' power state. **Connection details** contains the current status and transport. A previous sample remains visible as stale after reconnect or refresh, but controls remain disabled until a fresh sample arrives.

The panel shows opening progress immediately. After five seconds it explains that it is reconnecting once; after ten seconds it stops retrying and offers **Refresh**. Refresh starts a fresh read-only subscription and does not repeat any action. Readings become stale after three seconds without telemetry. The latest sample is cached locally so it can appear immediately after an app restart; cached readings are always stale and cannot enable actions until the Mac sends a fresh sample. The Mac stops sampling after fifteen seconds without a five-second renewal from the visible panel. Closing or backgrounding the panel sends Stop and cancels renewal.

## Meters and history

- **CPU** shows whole-system processor use from Mach host counters. The first sample can say “Collecting…” until the next counter reading establishes a baseline.
- **Memory used** shows physical memory minus free and cached memory against the physical total with Desk Deck v3. Details separate app, wired, compressed, other resident memory, cached files, free memory and swap. Cache is reclaimable and separate from used memory; swap uses disk space. Older Macs show **Memory (legacy)** with their category sum and an update explanation. Values are displayed in GiB.
- **Thermal pressure** shows macOS's nominal, fair, serious or critical state. It does not report sensor temperatures in degrees. See Apple's [thermal-state documentation](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum).
- CPU and memory history keeps the latest 60 points in memory. Disconnects create visible gaps; the app does not interpolate missing samples.
- The header shows Mac battery percentage, source and charging state, alongside the phone's own percentage and charging state. Unavailable and no-battery states remain explicit.

Meters refresh about once per second while subscribed. History clears when the selected trusted Mac changes or the app process exits.

## Quick controls and app shortcuts

- **Mute mic** sets mute on the current default input only when that CoreAudio device exposes a writable mute property. It is not a hardware kill switch and does not guarantee that every app uses that input.
- **Lock Mac** requests the public Control–Command–Q session-lock shortcut when Mac Event Posting permission is available. If it is missing, tap the tile for setup guidance; access is granted on the Mac.
- **Screenshot** opens the native macOS Screenshot controls. Choose an area, window or display, save locally, or cancel on the Mac. The phone confirms only that the controls opened; the image is not sent to the phone.
- **Do Not Disturb** runs the existing Shortcut selected in Mac Settings → Do Not Disturb. The shortcut must contain a working Focus action; an empty shortcut can finish without changing anything. aniCe reports whether the Shortcuts command finished, but does not read the resulting Focus state; check Focus on the Mac if it did not change. The selection is available to trusted phones until removed. Shortcuts use their own granted permissions, and Focus may sync when Share Across Devices is enabled.
- **Mac output volume** sets the current default output's absolute volume when macOS exposes a writable system control. A target change rejects stale writes; slider movement keeps only the latest queued value.
- The **Approved apps** grid shows apps explicitly allowed for that trusted phone in Mac Settings → Desk Deck. Pin and order shortcuts on the phone; Terminal and Blender are offered when installed. The Mac announces catalog changes to an open panel; the phone reloads pages for the new revision. The Mac resolves each opaque shortcut ID against its current approved bundle before launch.
- App approvals are tied to both the selected bundle and its executable file identity. Moving, replacing, or revoking the app invalidates the shortcut; reapprove a replacement in Settings → Desk Deck. Removing a phone's trust removes that phone's saved approvals.
- Brightness remains unsupported because macOS has no documented general display-brightness setter for this app; aniCe does not use private APIs or helper tools.

Every control has independent feedback. Actions require a fresh sample and are scoped to the current subscription. A request without a response is shown as unconfirmed and is never replayed automatically.

## Layout and screen behavior

Landscape presents meters and quick actions in an adaptive grid. Portrait stacks the same content naturally. The volume slider does not share a horizontal swipe-navigation surface; text follows Android font scaling and buttons retain touch targets of at least 48 dp.

**Keep screen awake while charging** is off by default. When enabled, it prevents the screen timeout only while Desk Deck is visible and Android reports external power; backgrounding, unplugging, or leaving the panel restores the normal timeout.

## Implementation and protocol

V1 through v3 remain available for older Macs. V3 adds app, cache, free and swap readings with explicit unavailable values. V4 adds the selected Do Not Disturb Shortcut while retaining the v3 sample shape. V2 supplies power samples, renewable subscriptions, and paged approved-app catalogs. Phone power is a separate authenticated shared capability, so Mac device status can show the phone's battery without opening Desk Deck. Neither capability opens a connection or extends another feature's lease.

See the [Desk Deck v1–v4 contract](../../protocol/desk-deck/README.md) and [Device Power v1 contract](../../protocol/device-power/README.md).
