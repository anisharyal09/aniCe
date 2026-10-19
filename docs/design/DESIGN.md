# aniCe design direction

Version 0.2 — reference-led overview and simultaneous activities. Evolve it through deliberate, documented changes as the product develops.

## Intent

aniCe should feel like a dependable personal utility: clear device relationships, useful controls, and familiar platform behavior. The interface helps someone understand the selected device, act on it, and recover when something is unavailable. It does not require them to understand the transport architecture.

Keep one recognizable design vocabulary across the full Mac window, its menu-bar companion, and Android. Adapt the controls and navigation to each platform. Consistency means shared concepts and roles, not identical pixels.

The feature panels in the concept demonstrate layout and interaction. They do not define an approved capability inventory, confirm OS support, or authorize implementation. Add functionality only when its product behavior and platform feasibility are established.

## Visual system

The palette uses warm neutral surfaces and a restrained **slate-blue** accent. Color should identify an action or state rather than decorate every module. Do not introduce an individual color theme for each feature.

| Semantic role | Light | Dark |
| --- | --- | --- |
| Background | ![#F4F3EF](swatches/F4F3EF.svg) `#F4F3EF` | ![#191E22](swatches/191E22.svg) `#191E22` |
| Content surface | ![#FFFDF9](swatches/FFFDF9.svg) `#FFFDF9` | ![#242B31](swatches/242B31.svg) `#242B31` |
| Sidebar / secondary surface | ![#EAEAE4](swatches/EAEAE4.svg) `#EAEAE4` | ![#20272D](swatches/20272D.svg) `#20272D` |
| Primary text | ![#262F35](swatches/262F35.svg) `#262F35` | ![#EDF0F1](swatches/EDF0F1.svg) `#EDF0F1` |
| Secondary text | ![#626E76](swatches/626E76.svg) `#626E76` | ![#ADB8BF](swatches/ADB8BF.svg) `#ADB8BF` |
| Separator / outline | ![#DCE0DF](swatches/DCE0DF.svg) `#DCE0DF` | ![#3C4850](swatches/3C4850.svg) `#3C4850` |
| Primary action / selection ink | ![#355B70](swatches/355B70.svg) `#355B70` | ![#A7C5D6](swatches/A7C5D6.svg) `#A7C5D6` |
| Text on primary action | ![#FFFFFF](swatches/FFFFFF.svg) `#FFFFFF` | ![#152D3B](swatches/152D3B.svg) `#152D3B` |
| Selected / subtle accent surface | ![#DDE8ED](swatches/DDE8ED.svg) `#DDE8ED` | ![#30434E](swatches/30434E.svg) `#30434E` |
| Success ink | ![#466A50](swatches/466A50.svg) `#466A50` | ![#A1C6A9](swatches/A1C6A9.svg) `#A1C6A9` |
| Warning ink | ![#825523](swatches/825523.svg) `#825523` | ![#DCB27C](swatches/DCB27C.svg) `#DCB27C` |
| Error ink | ![#A13D38](swatches/A13D38.svg) `#A13D38` | ![#E8AAA4](swatches/E8AAA4.svg) `#E8AAA4` |

Use semantic names in implementation and map them into native color roles. The success, warning, and error colors above are text/icon colors on neutral surfaces, not untested button fills. Brand accent is separate from connection success. Pair state color with text or a meaningful symbol.

- Follow system appearance by default. Offer System / Light / Dark in settings. Test each scheme rather than simply inverting colors.
- Prefer system type: macOS native text styles; Android Material text roles and scalable `sp`. Native accessibility settings take precedence over fixed concept dimensions.
- Home activity headings and device names provide labeled native actions to their feature or Devices page; essential navigation does not depend on a small chevron alone.
- Reference text sizes: Mac body 13–14 pt, secondary 12–13 pt, section title 14–16 pt, page title 24–28 pt. Android body 13–14 sp and supporting text 12 sp, mapped to Material roles.
- Use regular and medium weights for most content. Semibold can establish a heading. Avoid oversized title hierarchies, decorative display fonts in controls, or monospace as a technical costume.
- Use one native icon system per platform: SF Symbols on Mac and Material Symbols on Android. The browser concepts use Lucide only as a stand-in. Icons supplement essential labels.
- Spacing scale: 4, 8, 12, 16, 24, 32. Keep related content close and separate tasks with more space. Typical panel padding is 16–20, page padding 24–32 on Mac and 16–24 on Android.
- Reference radii: Mac small controls 6–8, content panels 10–12, floating companion 12; Android buttons use the small Material shape role (8-dp corners), with roughly 16 for grouped panels. Do not impose one universal rounded shape on everything.
- Borders and tonal surfaces provide grouping. Soft shadows belong mainly to floating surfaces. No colored halos, gradient text, decorative glass, bouncing panels, or pulsing connectivity.
- Require at least 4.5:1 contrast for ordinary text and 3:1 for large text and meaningful control graphics. Preserve visible native focus indicators and screen-reader labels; color must never be the only state signal.

## Application structure

Overview on Mac and Home on Android remain the initial destinations. Devices, Features, Favourites, Settings and About are separate sections. Mac exposes all six in its sidebar; Android uses five bottom destinations with a separate About route in the app bar. Do not put individual devices or Add device in the sidebar. Devices retains connection, LAN, pairing and trust management through the existing owners. Opening or closing a section never retires work by itself.

The overview is the initial destination and the single daily workspace for device state, sending files and active playback. Devices remains a connection-management section while the overview hosts daily activities. Features is a compact launcher with labeled panels for implemented capabilities, not a second dashboard containing every full panel. Each feature opens a dedicated panel with a Back action returning to Features or Favourites. Now Playing includes a collapsed Playback setup disclosure for integration and permission actions; it has no separate Phone controls launcher. Find Device retains its own request and permission controls. Every feature panel has a quiet trailing chevron. A separately labeled star toggles its local favourite shortcut; selected favourites appear on their own Favourites page, with a Choose favourites action when empty. Favourites do not enable features or bypass capability/permission gates. Send files opens its own panel using the existing file controls.

Primary peer lists show only secured peers while any are connected, otherwise trusted peers. Saved-device management remains available separately. Keep the selected device and operation target distinct: transfer panels name the authenticated peer and direction, and playback identifies its origin. A device picker changes presentation context, never silently reroutes an active job or playback command. Preserve other connected peers and their owners. The one-device case needs no picker.

## Full Mac window

Use a native resizable window with a toolbar branded aniCe and a sidebar matching the reference: aniCe heading, Workspace label, Overview/Devices/Features/Favourites above, Settings/About at the bottom. Keep semantic toolbar surfaces and dividers visible. Device context, readable connection state and a compact primary connection action lead the workspace. The overview uses a single device/status row with an immediately visible Auto connect checkbox and compact connection options. It omits device lists, setup text and Manage devices. Devices owns one compact connection card per currently connected peer, falling back to trusted peers when none is connected, with Auto connect, Bluetooth and LAN actions and a Security and diagnostics route. Add device opens pairing separately; trust management stays in a disclosure and This device is a quiet identity row. Connection details opens a sheet containing transport controls, security fingerprint and collapsed Diagnostics. Manage devices opens pairing and trust management. Security credentials remain selectable in their detail context; omit fingerprint prefixes from device summaries.

Sending files has one stable entry in the overview. An active transfer replaces the idle action with its approval/progress/result presentation. Local Mac playback remains optional and off by default for ambient workspace/companion cards. Opening Now Playing from Features explicitly presents its dedicated controls even when ambient display is off. Full playback and the compact activity share one owner. Overview music and files use responsive native panels: two columns when at least 320 points per panel fit, otherwise a single column. Feature launchers use one column below 700 points of detail width and exactly two above it. Both columns grow with the window; content has no fixed maximum width or artificial minimum card height. Overview panels switch to two columns at 720 points of detail width and never exceed two columns.

Without a trusted Android device, show No devices paired yet and Pair a device. The companion directs pairing to the full window. Preserve access to implemented local playback and settings. Battery, charging and storage have no placeholder values: battery/charging can enter the device header after authenticated data support exists; storage remains omitted.

## Mac menu-bar companion

The companion is for checking a device and taking a quick action. Browsing and configuration belong in the full window.

- Use a monochrome template status-item glyph and a native anchored panel approximately 340–360 pt wide.
- Show compact device rows with a small native name and connection status inline, a contextual connection action when disconnected and a details route. Wrap long names rather than increasing the normal row height for short names. Connected peers appear first; when any are connected, other peers remain accessible through the full workspace.
- Show Send files only for the actual ready, compatible transfer target and hide it during preparation or an active/result transfer. Do not attach a global transfer command to an unrelated connected peer.
- Use the original companion hierarchy: compact aniCe heading with overflow, device header, then content separated by quiet dividers only between populated sections. Do not place filled activity cards inside the companion surface. Playback and transfer remain discoverable together without paging, page counters or swipe gestures. Incoming offers remain immediately discoverable.
- Music has a Now playing heading and On this Mac origin. Keep artwork when available, title/artist, supported seek with elapsed/duration and balanced native transport buttons visible. Play/pause is a circular accent control. Full playback keeps the Player selector visible with Auto and advertised sources. The companion also shows it when multiple players exist; More playback controls reveals compact player volume; it does not hide ordinary seek controls. Missing artwork stays absent.
- Find Device remains in its feature panel. Clipboard opens its native text-sharing panel; battery and charging remain absent until their data and behavior exist. No disabled future-feature placeholders or permanent Quick actions heading.
- Send clipboard and Send files are quiet labeled controls below the current activity, wrapping vertically when needed. Send files names its ready target. The footer is a quiet Open aniCe route with a trailing arrow; Settings, Manage devices and Quit live in the header overflow. Modal pickers retain the companion and restore focus. Dismissal never means cancellation.
- Bound content to the screen with scrolling and a persistent footer. Native Escape/outside-click dismissal, keyboard access and VoiceOver must be verified. Sharing owners with the main window prevents a separate capability or transport model.

Left-click toggles the AppKit status-item popover. Right-click/Control-click opens native window routes and Quit. Opening a route updates peer context before activating the window. Clicking a companion device name, row or chevron opens Devices without automatically presenting a connection-details sheet. Background events never open the panel or take focus. Closing a window leaves existing background ownership intact; Quit remains explicit.

## Mac Quick Paste Tray

The Quick Paste Tray accepts keyboard focus across applications without activating aniCe or becoming the main window.

- **Floating presentation**: Up to 760 pt wide, 292 pt high non-activating panel (expanding up to 460 pt for full-text preview) (`NSPanel.nonactivatingPanel`, floating level) anchored at the bottom-center of the screen above the Dock. Dismisses on blur or outside click. Escape first exits search or full-text preview, then closes the tray.
- **Surface & typography**: Uses `AniCePalette.surface` with a 1 pt `AniCePalette.separator` border and 14 pt corner radius. Follows system typography without decorative display fonts or bouncing animations.
- **Card carousel**: Horizontal scroll view with compact 168×152 pt cards spaced by 10 pt. Unselected cards use `AniCePalette.secondarySurface`; selected cards highlight with `AniCePalette.subtleAccent` and an `AniCePalette.accent` stroke.
- **Smart previews**:
  - Valid CSS hex colors show a 28x28 pt live color swatch and monospaced code.
  - URLs show an accent link symbol and domain preview.
  - Code-like content renders in monospace.
  - Origin badges identify "Mac" or "Phone" sources; pinned items display a warning-colored pin badge.
- **Shortcuts & navigation**:
  - `⌥⌘V` toggles the panel globally.
  - Typing filters history in real-time.
  - Space expands the selected item into a scrollable, selectable full-text preview in the same panel. Space or Escape collapses it without copying. Left/Right switch items in the preview; Up/Down remain available for scrolling.
  - Opening focuses the selected card for immediate arrow navigation. Typing enters search; spaces and Left/Right retain native editing while the search field is focused. Command-F focuses search. Up/Down return from search to card navigation. Return copies the selection and closes after a successful write. Escape exits search or preview before closing the tray.
  - Search and category filters occupy separate rows. Pin and Delete remain visible and keyboard accessible. Selection follows the entry identity through pinning and deletion.
  - A small tray icon sits beside Send clipboard in the companion and remains available without a connected phone. Opening it closes the companion, resets the query/filter, and focuses card navigation. Failed native copies keep the tray open with an error.
  - Enabling history from the tray requires the same local-storage consent as the History panel.

## Android

Use a native top app bar and five bottom destinations: Home, Devices, Features, Favourites and Settings. About opens as a separate page from the app bar. Home contains device summaries, file sending and relevant playback; Devices uses native separated peer rows with status, automatic preference, LAN action and a security/diagnostics disclosure; it avoids nested or decorative card boundaries. This device remains a quiet navigation row; This device and Add device are full-width rows at the end of the Devices scroll content. Features and Favourites use one full-width card per row on phones. Phone Home shows one compact device/status row with 8-dp additional vertical space above and below; automatic connection preferences stay directly accessible in Devices rather than Home. Its aniCe app-bar brand stays visible. Device lists, management, LAN actions and the This device identity route belong in Devices. Omit a redundant Connections heading below the Devices app bar.

Use native pickers, sheets, dialogs and scalable Material type. Home player volume uses one slim label/slider/value row while retaining its 48-dp interaction target and source-bound release behavior. Phone feature headings and device names use title-small roles, track titles use body-medium and supporting artist/origin text uses body-small; accessibility scaling remains native. Details stack at compact widths; do not force feature panels into equal-size tiles. Wider screens may use native navigation rails. Device names wrap; unknown facts stay absent. Full fingerprints live in selectable Connection details content. Automatic Bluetooth setup is directly accessible outside Connection details, preserving the existing permission/association flow. Incoming Find Device ringing and Stop remain native alert/notification behavior, independent of the Features launcher.

Back closes expanded details or a feature setup view, then nested pairing/discovery or identity settings, then returns to the overview. Returning to the overview through navigation exits management without cancelling its owner. Successful pairing returns to the overview after authenticated trust activation and cleanup. Media notification taps open the dedicated Now Playing panel.

Apply safe drawing insets exactly once through Scaffold and child inset consumption. Test gesture/three-button navigation, cutouts, keyboard, scaled text and minimum 48-dp targets. Preserve RTL-aware Back and native focus order. Discovery browsing preserves existing transports; explicit Scan takes exclusive Bluetooth ownership. LAN remains subject to existing foreground/approved-work limits.

## Live activities

Current transfers and playback share the workspace and companion, with one content-bearing surface per activity. Present both simultaneously when relevant. Do not reserve empty slots, paginate two active operations, auto-rotate or add horizontal swipe to slider-bearing controls.

Supported playback seek is visible in the compact player. Full Now Playing exposes player selection directly. More playback controls reveals secondary controls locally without sending a command. Bind seek and volume commands to the captured source/revision and send once on release; discard gestures when their target changes. Closing secondary controls discards their unfinished gesture. Respect reduced motion and stop local progress clocks when hidden or paused.

Transfers retain explicit approval, destination choice, progress, cancel and result recovery. Show direction, peer and measurable rate. A paused transfer presents a frozen determinate progress bar, the pause reason, direction and peer, and Cancel; either device with a secured Bluetooth channel also gets Continue over Bluetooth, and the device without one states that it is waiting for the connection. A paused batch keeps its progress and partial while the user decides. Pause is automatic on transport loss only; no manual pause control is offered while a channel is healthy. Incoming events remain visible without opening a panel or stealing focus. Brief results are dismissible; dismissal never cancels an operation. Android Home, the Mac overview and the Mac companion can show the latest successful clipboard activity for five minutes, independently of saved Clipboard history. It exposes origin, direction and time, a two-line eligible-text preview bounded to 240 characters, an Open Clipboard heading, labeled Copy and Dismiss. The Mac companion keeps it flat within its existing surface. Sensitive/generated items retain metadata only. The activity remains process-local and is removed on expiry, dismissal or trust/identity invalidation.

## Connection experience

A device-level summary says Connected only after a secured transport is ready. Keep detailed Bluetooth/LAN status, security and diagnostics in Devices. Show the automatic preference outside the details disclosure. Keep device-level Disconnect directly accessible on phone Home and in Mac Home/companion menus. Failures and pending work stay truthful and recoverable. Automatic Bluetooth uses existing native setup and eligibility; manual admission retains its bounded window.

Settings and pairing expose **Use local network automatically** on both platforms; pairing presents one **Connect automatically after pairing** toggle that sets both the Bluetooth and LAN choices. Both local preferences and secured BLE are required. The preference is on when unset, and an explicitly stored off wins. Automatic LAN uses bounded Mac admission and Android foreground/interactive discovery, on connection events, ordinary secured BLE feature activity, explicit feature demand or an active companion media demand lease (including background Now Playing). LAN coordination and keepalives never initiate another attempt. Failed or expired attempts wait for another event; BLE retains reconnection ownership. Manual Disconnect pauses automation until manual reconnect or a preference change; feature traffic does not resume it. Devices exposes the existing controls directly and the Mac overview connection-options menu retains Allow LAN. A transfer uses the best already-secured compatible channel; a capable local network upgrades an active Bluetooth stream in place through the resume handshake instead of waiting for the next batch. A channel loss pauses it instead: the transfer keeps its approved lease, LAN eligibility and a secured Bluetooth fallback, local network reconnection resumes it automatically, and Bluetooth continuation after a local-network pause is an explicit action on either device (the receiver then asks the sender to validate the retained prefix). Send and file selection request LAN without retiring a secured BLE channel; picker leases follow secured transports rather than the transiently selected channel. Android's background timeout stays collapsed under a single row and defaults to Never. No UI redesign changes authentication, consent, radio exclusivity or background eligibility.

## Clipboard preference

Clipboard behavior and platform limits are recorded in [Clipboard](../features/CLIPBOARD.md). Automatic Android reading requires actual focus; background incoming writes replace the clipboard without conflict detection. Mac automatic reading respects supported pasteboard access behavior. Manual receiving remains available when automatic mode is off.

Settings presents **Automatic clipboard sharing** as a toggle. It is off by default: off means manual sharing, with an explicit Send action. On means automatic sharing for the selected trusted-device relationship when the platform and permissions support it.

Keep the choice scoped to the paired device and synchronized across its app surfaces. Reflect the current mode in the clipboard panel and quick action; turning automatic sharing off immediately returns the interface to manual sharing. Do not label a requested mode as active if a required permission or platform capability is unavailable. Show the reason and available manual route.

Native implementation must establish clipboard access, direction, loop prevention, and private-content handling before enabling automatic sharing. Native Clipboard v1 uses direct native delivery, manual Send and one per-credential automatic preference controlling sending and automatic receiving. Inspection within Share starts with metadata and explicit Reveal. The Clipboard panel retains native Share and History views. Send clipboard and Send files use quiet native outlined/bordered controls with a small symbol and visible action label; they are one-shot actions, separate from the automatic-sharing toggle. Android preserves 48-dp touch targets, 8-dp corners and neutral semantic ink. Mac uses small native bordered buttons, including direct clipboard/file actions in the companion. Share keeps device context, automatic consent, Send clipboard and meaningful status visible; More options holds inspection, Reveal and manual paste, with detailed guidance under How sharing works. History is a separate device-local opt-in with compact two-line text rows, From Mac/From phone labels, timestamps, Copy/Send/Delete and confirmed Clear all. Clipboard preferences use compact native checkboxes matching the local-network automatic preference, with the shared selection accent in both appearances. Keep clipboard history is shared between Settings and History, defaults off, and explains local persistence before enabling. Turning it off pauses collection while preserving saved items across restart, Forget device, and Reset identity. Explicit Clear/Delete remove items; count limits still bound retention. Both platforms offer 20/50/100-item capacities and 4-point/dp horizontal breathing room within the Clipboard panel. History groups entries by local calendar date, newest first, with a saved-count/Clear all toolbar, wrapping origin/time metadata and quiet labeled row actions. History remains accessible without a peer. Android provides a compact Send to Mac panel for selected text and Share-sheet text or URLs; it does not open the full workspace. The browser sample never accesses the clipboard.

Android 10+ restricts clipboard reading to the app that currently has input focus or the default input method editor (IME) ([clipboard privacy restrictions](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data)). For aniCe's ordinary app, automatic reading must be limited to periods when it has focus; do not implement continuous background clipboard monitoring or assume a foreground service grants access. The Send to Mac Quick Settings tile opens a focused explicit-send panel. It reads once after actual focus, displays metadata and requires Send, preserving sensitive-marker confirmation. That focus grants manual read access without enabling automatic sharing or history observation. The tile is not a clipboard-access exemption; its system-bound service never reads the clipboard or starts connections. Do not introduce an IME or sandbox bypass merely to enable clipboard sharing.

## Panel and interaction rules

A panel groups one task. It earns its boundary through content and controls, not an icon plus marketing sentence. Size panels to their task; do not pad every panel to the same height or put a card inside another card.

Each module may provide an overview panel, a fuller view, and a quick action only when each is useful. Those surfaces reuse the same device context and state. A panel typically contains a clear title, source/destination when relevant, meaningful content, and one main action with quieter secondary controls.

Use ordinary verbs and precise destinations: “Send to Pixel 9,” “Playing on your Mac,” “Received from phone.” Prefer “View files” over unexplained metaphors. Never describe an action as available just because the design has a button.

Keep feedback near the initiating action. Multi-step work shows its state and offers recovery. Confirm destructive trust removal or genuinely sensitive choices; do not interrupt routine actions unnecessarily. Private content needs deliberate preview and permission behavior before implementation.

Press feedback is immediate. State transitions are brief, generally 150–220 ms when animation helps explain a change. No choreographed page entrances or artificial waits. Respect native reduced-motion settings and keep ongoing interaction interruptible.

## State truth

Connection, trust, support, permission, and enabled state are separate facts.

| Situation | Required presentation |
| --- | --- |
| Offline | Say offline and provide a useful next step; label cached information as last known. |
| Unknown data | Show unavailable or unknown, never an invented zero. |
| Permission needed | Explain why and offer the appropriate permission flow. |
| Unsupported capability | Explain availability; do not offer setup that cannot work. |
| Disabled feature | Offer an explicit way to enable it when appropriate. |
| Loading | Keep layout stable; use a bounded placeholder or pending control. |
| Empty active feature | Explain the first useful action. |
| Interrupted operation | Describe the result and recovery; preserve progress when supported. |

Stale media or device facts must not appear live. Disable only the controls that cannot work; preserve access to details, settings, and navigation.

## Design-agent rules

Before any UI work, read this guide and the relevant product/protocol documentation. Then:

1. Preserve the vocabulary, semantic tokens, hierarchy, and native platform behavior. Reuse existing components before inventing new treatments.
2. Add only the functionality established by the current task. Sample panels and possible modules are not implementation requirements.
3. Keep device scope, direction, availability, and private-content behavior truthful across all surfaces.
4. Use content-bearing panels. Avoid equal-size feature tile walls, nested panels, unrelated dashboard metrics, ornamental status graphics, or a new accent per feature.
5. Keep primary actions focused and labels explicit. Essential actions must be accessible without hover.
6. Do not silently rebrand, rearrange shared navigation, or fork the design system per screen. Explain and record a justified design change in this guide when the task authorizes it.
7. Treat sketches as sketches. Browser review verifies the concept only; native verification requires the actual app.
8. Preserve simultaneous live activities and the automatic/manual clipboard preference when clipboard support exists. Do not reintroduce storage into the device summary or invent replacement metrics without a product requirement.
9. Disable card swiping on slider-bearing activities, handle Android safe drawing insets without duplicate padding, and verify native menu focus/dismissal before selecting any AppKit fallback.

Review meaningful UI changes in both themes, compact/expanded widths, large text, long device names, empty/offline/permission states, keyboard/focus order, and screen-reader labels. Test native Android touch targets and Back behavior, and native Mac menu focus/dismissal separately when implemented. Use bounded review passes and fix discovered issues together.

## Design references

- [Impeccable by Paul Bakaus](https://github.com/pbakaus/impeccable): primary design guidance, especially Operate, craft-floor, and native adaptation principles.
- [Design skills by Emil Kowalski](https://github.com/emilkowalski/skills): supplemental Apple-style interaction and design-engineering guidance. Native platform rules take precedence over its web implementation examples.

The ignored local self prototyped images (designed by anisharyal09) under `for-me/` were used as design references. They are not runtime dependencies and do not need to be published with aniCe. This guide captures the project-specific rules; the upstream links remain accessible to contributors.

## Transport connection details

Each device has one readiness-based summary and a compact primary Bluetooth action. Only secured transports appear in Connected; pending/failed secondary channels retain separate feedback. Device-level Disconnect closes both owners; transport-specific actions close only their channel. LAN retains manual controls alongside the opt-in automatic policy. Mac Connect opens bounded admission and waits for the phone.

Ordinary buttons, navigation titles and close symbols use neutral primary/secondary ink. Automatic checkmarks alone retain the shared accent (light #355B70, dark #A7C5D6); state colours remain separate. Android uses native outlined/text controls with 8-dp corners, 10×4-dp standard content padding and 14×2-dp connection-action padding. Connection action visuals have a 32-dp minimum height; native Material interaction bounds remain 48 dp and scalable text may increase visual height. Android automatic preference is observable application state presented outside Connection details as a compact native checkbox in one accessible 48-dp row. The close symbol is 18 dp inside its native 48-dp icon-button target.

Android Devices presents Bluetooth and Local network as direct compact rows beneath the device name, readiness and automatic preference. Security and diagnostics expands inline from a full-width disclosure with a chevron and accessible expansion state. Device-level Disconnect remains in the expanded details. System Back, its labelled close icon or Connection details action collapses presentation without retiring work. Diagnostics is a full-width disclosure with accessibility state; it owns the association-settings route, connection checks/counters, Debug automatic-service events, discovery compatibility and LAN lifetime information. Debug service events are a separate collapsed disclosure, reset whenever Diagnostics opens. Association settings uses the native RTL-aware Back icon and contains no duplicate diagnostics. Opening Bluetooth discovery preserves both transports. Scan suspends/retires Bluetooth only; automatic ownership resumes after discovery cleanup. LAN remains active and device-level Disconnect still closes both transports. Trusted-device management shows full names and separate confirmed Forget actions; clicking a device name expands its selectable full fingerprint. Phone trusted-device rows include a Security fingerprint subtitle and a mirrored chevron indicating expansion. Disclosure labels activate their entire row on both platforms. Android Settings uses the title aniCe Settings. Device summaries omit fingerprints; security details retain the full credential. LAN progress identifies the existing 15-second browse before resolution/authentication.

Mac workspace sections fill the available width. Connection details uses a sheet. The companion has bounded 520-point scrolling and a persistent footer. A quiet Send files row names the ready transfer target. Transfer and playback use flat sections with visible supported seek, secondary playback controls and modal picker focus restoration. Physical persistence, sizing, focus and VoiceOver acceptance remain pending.

Manage devices preserves existing sessions while browsing; pairing/discovery still acquires exclusive radio access. Pairing offers separate automatic Bluetooth and LAN choices before approval. After mutual trust activation and guarded native cleanup, both apps return to the overview and start fresh Bluetooth work. Android first enable requires its native permission/association dialogs; remembered setup resumes inline without a settings-page flash. Android disable releases automatic/background ownership but retains eligible secured foreground work as manual; background/lock cleanup and hard limits remain. Automatic setup remains subject to platform/build availability.

This device uses a compact name/platform header. Android shows a title-medium name, 28-dp phone symbol and 12-dp panel padding, with RTL-aware Back. Copy actions sit beside identity labels. Edit name uses a native dialog accepting 1–64 trimmed Unicode code points; atomic writes preserve device ID/key material and recover without replacing identity after failure. Reset remains under Advanced with confirmation. Its entry control uses compact neutral outlined styling; destructive color belongs to the final confirmation action. Existing authenticated snapshots do not update display names until a subsequent identity exchange.

## Appearance and local identity

Settings contains This device, with editable name, identity details and confirmed reset, while the separate About section contains aniCe, the installed version, “Connect your Mac and Android.”, separate source-code and GPL-3.0-or-later license links, and an author link to https://anisharyal09.com.np/. Phone and Mac About retain a Made by website credit and separate source and license links. About ends with a horizontally centered heart-only support link to https://anisharyal09.com.np/support?from=anice, using a subdued outline heart and the accessible label Support aniCe. Advanced stays collapsed. Navigation and appearance never cancel transports.

The Android LAN background timeout defaults to Never; explicitly saved timeout choices are preserved. Ordinary BLE feature traffic initiates LAN when missing, subject to both preferences, eligibility and local Disconnect pause.

Appearance is saved locally as System, Light or Dark, defaulting to System. Android applies it to the main app and association settings. Mac labels it Window appearance, uses a native menu picker and applies it only to the main window. System resolves its scheme from observed application appearance independently of the window. The resolved preference applies through SwiftUI’s presentation-level preferred color scheme to both the window and connection-details sheet, including native controls; the sheet uses the matching semantic surface and text colors. Later macOS appearance changes update System mode without changing a forced Light or Dark preference. The companion, popover and native context menus follow macOS appearance and resolve their colors independently. Companion deep-links update the shared destination and peer context before restoring and activating the main window, including when it is already on Settings.

Native focus, screen-reader operation, opposite window/system appearances, large text and physical connection continuity require interactive verification; hosted/unit checks do not establish these results.

## Now Playing

Navigation keeps Overview/Home, Devices, Features, Favourites and Settings, with About as its own section. Features launches each capability in its own panel. Playback setup stays inside Now Playing. Compact music names its playback origin and keeps supported seek visible. More playback controls reveals secondary controls in place. Playback buttons use native icons and accessible labels. Ambient Mac playback remains optional and off by default; explicit Now Playing access remains available. Phone subscriptions are independent. Genuine playback is required for ambient cards, with paused resumable sessions retained for a 90-second grace period.

Full playback presents available artwork/title/artist/player/state, Auto/player picker, locally advancing elapsed/duration and advertised controls. Missing metadata stays absent; unsupported actions are disabled. Unknown duration or unsupported seek omits the slider. Scrubbing captures source/revision, sends once on release and cancels on replacement. Android slider and elapsed label share atomic dragging, pending preview and authoritative state. Keep the thin track, small thumb, aligned monospaced labels and a 48-dp accessible interaction area; acknowledgement does not disable scrubbing or confirm position. Supported selected-player volume uses an integer 0–100 slider and one command on release. Slider-bearing activities have no swipe gesture. Hidden/paused/disconnected presentation stops progress animation. Permission-needed feedback directs Android to the explicit Mac permission action.

Artwork has a reserved placeholder on both platforms so asynchronous delivery does not shift track text. Clickable activity headings include a forward chevron. Mac Settings and About use a maximum 680-point reading width while activity panels remain fluid. Artwork is in-memory and LAN-only; Bluetooth still supports metadata and advertised controls. Native palettes, accessible labels, wrapping text and native touch/focus bounds remain shared. Android presents supported playback through native MediaSession/MediaStyle notification and lock-screen controls, on a silent channel. Tapping opens the dedicated Now Playing panel. Playing restores compact surfaces; pausing starts one monotonic 90-second grace period that metadata updates cannot extend. Expiry hides compact cards and system presentation while explicit the overview playback retains current paused controls. Background presentation requires existing valid companion ownership and an already-secured BLE channel, with no artwork or progress polling. A separate media foreground service remains excluded. See [Now Playing](../features/NOW_PLAYING.md) for acceptance status.

Features explains player-control discovery, unsupported actions, permission requirements and temporary unavailability. Refresh preserves selection and never prompts. Player-volume previews retain the requested value through asynchronous execution until a matching sample or readable failure/timeout feedback. Unsupported browser/wrapper player volume remains distinct from Mac output volume.

Phone volume buttons control separately advertised Mac output volume while genuine compact playback is active. Full detail labels this Mac output control and its current percentage/availability; the Player volume slider retains its selected-player meaning. Device replacement/retirement clears preview and unsent key intents, without volume-command replay. Unsupported output control preserves foreground Android key routing.

## Find Device

Features presents a labeled Find Device panel opening peer-scoped request actions, local permission setup and notification settings. The panel shows connected peers while any are connected, falling back to saved peers with Devices connection guidance when none are connected; connected peers without a capability advertisement show that fact instead of being described as unsupported. Empty trust inventories show a pairing instruction. Device summaries and the companion omit Find Device. Pending feedback names its peer and distinguishes OS submission from display or sound, with unsupported and blocked states kept separate from connection readiness. Incoming requests never open permission prompts or take application focus. Native alerts localize the authenticated peer name. Mac retains notification Dismiss. Android rings at its current alarm volume for at most sixty seconds, exposes Stop ringing in a foreground notification, and shows a native alert dialog while the app is open. Dialog dismissal and Stop end playback; no background activity or lock-screen overlay is forced. Explain that Silent/Vibrate differs from muted alarm volume and DND.

Find Device permission actions wrap on narrow Android layouts and retain 48-dp touch targets. Mac permission feedback wraps vertically; peer actions retain their intrinsic width beside wrapping device names.
