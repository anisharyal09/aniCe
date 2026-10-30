# aniCe design direction

Version 0.3. This guide defines visual direction and presentation behavior; feature docs and protocol contracts define capabilities and data. Browser concepts use sample data and do not imply unavailable capabilities.

## Intent

Keep the selected device, available actions and recovery path clear across surfaces. Use familiar platform behavior; do not expose transport architecture in ordinary workflows.

Share semantic roles across Mac, its menu-bar companion and Android; use each platform's native controls and navigation.

Feature panels demonstrate layout and interaction, not capability availability or OS support. Implement only established product behavior that the platform supports.

## Reference fidelity

The approved reference is the visual target. Preserve its hierarchy, proportions, typography, outlined actions, sidebar branding, grouped connection rows, flat Home player, file-selection target, and Mac pairing/detail sheets. Match each platform before moving to another area. Adapt only where native behavior, supported capabilities or accessibility require it. Use Choose files unless native drag-and-drop is implemented; pairing requires mutual approval rather than the simulator’s Continue action.

## Visual system

Use warm neutrals with charcoal-green action ink. Do not use indigo, slate-blue or blue glow as the product accent. Color communicates action and status, not feature categories. Balance both appearances.

| Semantic role | Light | Dark |
| --- | --- | --- |
| Background | [![#F4F3EF](swatches/F4F3EF.svg)] `#F4F3EF` | [![#1B1E1E](swatches/1B1E1E.svg)] `#1B1E1E` |
| Content surface | [![#FFFDF9](swatches/FFFDF9.svg)] `#FFFDF9` | [![#242828](swatches/242828.svg)] `#242828` |
| Sidebar / secondary surface | [![#EAEAE4](swatches/EAEAE4.svg)] `#EAEAE4` | [![#222626](swatches/222626.svg)] `#222626` |
| Primary text | [![#282E2A](swatches/282E2A.svg)] `#282E2A` | [![#EBEEEB](swatches/EBEEEB.svg)] `#EBEEEB` |
| Secondary text | [![#626B65](swatches/626B65.svg)] `#626B65` | [![#ADB5AF](swatches/ADB5AF.svg)] `#ADB5AF` |
| Separator / outline | [![#DCDED8](swatches/DCDED8.svg)] `#DCDED8` | [![#3B4140](swatches/3B4140.svg)] `#3B4140` |
| Primary action / selection ink | [![#47534D](swatches/47534D.svg)] `#47534D` | [![#C4CCC5](swatches/C4CCC5.svg)] `#C4CCC5` |
| Text on primary action | [![#FFFDF9](swatches/FFFDF9.svg)] `#FFFDF9` | [![#222A25](swatches/222A25.svg)] `#222A25` |
| Selected / subtle surface | [![#E5E8E2](swatches/E5E8E2.svg)] `#E5E8E2` | [![#303632](swatches/303632.svg)] `#303632` |
| Control track | [![#E0E3DC](swatches/E0E3DC.svg)] `#E0E3DC` | [![#3B413E](swatches/3B413E.svg)] `#3B413E` |
| Success ink | [![#466A50](swatches/466A50.svg)] `#466A50` | [![#A1C6A9](swatches/A1C6A9.svg)] `#A1C6A9` |
| Warning ink | [![#825523](swatches/825523.svg)] `#825523` | [![#DCB27C](swatches/DCB27C.svg)] `#DCB27C` |
| Error ink | [![#A13D38](swatches/A13D38.svg)] `#A13D38` | [![#E8AAA4](swatches/E8AAA4.svg)] `#E8AAA4` |

Use semantic names in implementation and map them into native color roles. Success, warning, and error colors are for legible status on neutral surfaces, not untested button fills. Action ink is not a connection indicator. Pair every state color with text or a meaningful symbol.

- Follow system appearance by default. Offer System / Light / Dark in settings. Test each scheme rather than simply inverting colors.
- Prefer system type: macOS native text styles; Android Material text roles and scalable `sp`. Native accessibility settings take precedence over fixed concept dimensions.
- Home activity headings provide labeled native feature actions; device names open connection details; essential navigation does not depend on a small chevron alone.
- Reference text sizes: Mac body 13–14 pt, secondary 12–13 pt, section title 14–16 pt, page title 20 pt. Android app brand 17 sp, page title 20 sp, section title 14 sp, body 13–14 sp and metadata 12 sp, mapped to native roles. These are starting values; native Dynamic Type and font scaling remain authoritative.
- Use regular and medium weights for most content. Semibold can establish a heading. Avoid oversized title hierarchies, decorative display fonts in controls, or monospace as a technical costume.
- Use one native icon system per platform: SF Symbols on Mac and Material Symbols on Android. The browser concepts use Lucide only as a stand-in. Icons supplement essential labels.
- Spacing scale: 4, 8, 12, 16, 24, 32. Keep related content close and separate tasks with more space. Typical panel padding is 16–20, page padding 24–32 on Mac and 16–24 on Android.
- Reference radii: gently rounded rectangles, typically 6–8 pt/dp for controls and 8–12 for content groups; floating surfaces may use 12–14. Avoid pill-shaped controls and excessive nested boxes. Do not impose one universal radius on everything.
- On Mac, distinguish the titlebar, sidebar and workspace with neutral surface tones and visible dividers in both appearances.
- Borders and tonal surfaces provide grouping. Soft shadows belong mainly to floating surfaces. No colored halos, gradient text, decorative glass, bouncing panels, or pulsing connectivity.
- Buttons use lightly outlined or neutral-filled rectangles with modest rounding. Reserve filled emphasis for the primary action; keep secondary actions subdued.
- Require at least 4.5:1 contrast for ordinary text and 3:1 for large text and meaningful control graphics. Preserve visible native focus indicators and screen-reader labels; color must never be the only state signal.

## Navigation and continuity

The information architecture is shared, while its navigation is native:

| Destination | Purpose |
| --- | --- |
| Overview / Home | Device context, current playback and transfer, recent activity, quick sends |
| Devices | Connection, pairing, trust, identity and diagnostics |
| Features | Launch supported feature panels and their local preferences |
| Favourites | Shortcuts to chosen Features; never enable or bypass a feature |
| Settings | Appearance and app-wide preferences |
| About | Version, license, source, developer, social and support links; compact rows reflow when space or text size is tight |

On Mac, the window titlebar is split at the sidebar boundary. Keep macOS traffic-light controls at the far left, then Back and Forward history controls on the left portion. Show the aniCe brand in the window header, not the active destination name. Keep the active section title small in the workspace. History navigation follows actual visited pages, including conversation changes; Back returns to the prior page context. The sidebar holds Overview, Devices, Features and Favourites, with Settings and About at its lower end.

Android uses a native app bar and five bottom destinations: Home, Devices, Features, Favourites and Settings. About is reached from the app bar. Preserve system Back and RTL-aware in-app Back. Keep aniCe in the app bar and use restrained destination headings in the body, as in the approved reference.

Opening or leaving a section never retires a transport, playback session, draft or transfer. A feature panel's Back returns to its entry destination: Home/Overview, Features or Favourites. Feature settings open inline from that feature's gear; they edit the same preference and do not send the user to the global Settings page. Main Settings remains available for app-wide discovery and management.

## Screen specifications

### Delivery priorities

| Priority | Design outcome |
| --- | --- |
| P0 · Task completion | Stable device context; pairing with mutual approval; file review/progress/result; bottom SMS composer with explicit SIM; retained drafts; distinct offline, permission and uncertain-send recovery |
| P1 · Continuity | Shared state vocabulary; contextual Back; separate favourite and open actions; Mac history-aware Back/Forward; inline feature preferences; active work remains visible across navigation |
| P2 · Finish | Optical alignment; keyboard paths; reduced motion; long-content wrapping; understated status labels; native notifications; localization |

### Before → after rationale

| Area | Before | Redesign outcome |
| --- | --- | --- |
| First run | Setup competes with the workspace | One pairing path, identity review, mutual approval and return to Home |
| Home | Repeated context and competing panels | One device row, compact actions, active work first and recent activity secondary |
| Devices | Connection details spread across sections | Peer readiness, direct connection actions and security disclosure in one group |
| Features | Large cards and unclear destinations | Flat labeled rows; open and favourite are separate actions |
| Now Playing | Controls are scattered or off-center | Center the player around its source, supported seek and transport controls |
| Files | Send actions compete with transfer state | One compact entry that progresses through choose, review, send, progress and result |
| Messages | Composer placement and active selection interrupt reading | Chronological history, subtle selection, neutral received messages, SIM beside bottom Send |
| Clipboard | Sharing, history and preference controls are mixed | Task-focused Share/History with consent in Settings and inline feature preferences |
| Settings | Verbose and box-heavy | Mac preference groups; concise phone rows; consistent whole-row activation |
| Menu bar / tray | Oversized or unresponsive quick surfaces | Compact quick actions and keyboard-oriented tray with stable selection and focus |
| Errors and empty states | Dead ends or generic status | One truthful explanation and one relevant recovery action |

### First run and connection

Keep pairing separate from the everyday workspace. Give first run one clear Pair device action, then explain QR or code pairing in short steps. Show identity details before approval; require approval on both devices. Denial returns to a recoverable pairing state. Request OS permissions only in the context that needs them and explain the next system step. A successful pairing returns to Home with the connected device named.

Connection state must distinguish trusted, connecting, secured, offline, permission-blocked and unsupported. Never imply an authenticated connection from discovery alone. Offer one contextual next action. Keep manual connection and automatic preference visible where the user manages devices.

### Home and Overview

Show one device row with its name, readiness state, Auto connect where appropriate and a compact Disconnect/Connect action. Keep connection management and device lists in Devices.

Place compact Send files and Send clipboard actions below the device row. Keep simultaneous current playback and file-transfer activity visible together when space permits. Show activity only when relevant; do not reserve empty cards. Recent clipboard, messages and completed transfer are secondary rows below current work. High-activity incoming approval takes visual precedence and remains visible while navigating. Do not invent battery, storage or charging values.

### Devices and device details

Show a flat peer group with device name, secured readiness, automatic preference and direct Bluetooth/local-network controls. Separate rows with subtle dividers and reflow controls at narrow widths. Keep Security and diagnostics in a disclosure. Use short curved divider edges above Auto connect and after Security and diagnostics; leave the group open-sided without a surrounding card. On phones, align device headers, connection rows and lower disclosures to one gutter; extend curved divider ends 8 dp beyond it. Give outlined device actions a neutral surface fill. Keep Trust and saved devices and This device at compact Mac row heights with four-point gaps. Keep Add device and saved devices separate from the active peer. From Devices or Settings, This device opens the same native identity sheet and returns to its originating section when closed. Allow selection of names and full fingerprints in security details; omit fingerprint fragments from summaries. Confirm Forget.

### Features and Favourites

Present a compact launcher as clear flat rows, not a wall of equal large tiles. Each row has a neutral icon, feature name, concise current availability or state, separate favourite control and trailing chevron. Entire row opens the feature except for independent star or overflow controls. On Mac use two columns only when the detail width supports readable rows; on phones use full-width rows. Favourites use the same feature destination and permission rules as Features.

### Now Playing

Keep the compact Home player concise: artwork when available, title, artist/origin, supported seek and balanced transport controls. The dedicated Now Playing page centers the content block in the available workspace with a readable maximum width. Do not leave an unexplained empty right-hand region or over-expand controls. Order content as player/source, artwork and metadata, elapsed/seek/duration, transport, output volume and collapsed Playback setup. Keep the player selector visible. Missing metadata stays absent; unsupported controls explain their state. Use low-emphasis neutral feedback, especially in dark mode; received SMS bubbles and active selection must not look brightly highlighted.

### File transfer

Keep the overview and menu-bar send entry compact. Show Choose files; only promise drag-and-drop when native support exists. Review selected files and named target before sending. Require review and approval for incoming files. Show direction, peer, progress and result or recovery action. Closing a surface does not cancel a transfer.

### Messages

Use the same conversation hierarchy on both platforms, adapted to native navigation. Mac uses a conversation list beside the selected thread when width permits; Android focuses on one thread and uses Back to return to the list. Show message history in chronological reading order and keep the composer at the bottom. Keep SIM choice directly left of Send. Retain drafts when switching conversations or leaving and returning. Clearly distinguish Sending, Sent, Failed and Not confirmed; do not encourage a blind retry after uncertain delivery. Keep received message surfaces neutral and active-thread highlighting subtle in both themes. Remove the carrier-charge disclaimer from this UI.

SMS permissions and actual relay capability are distinct. If SMS is uncommon for a person, it remains discoverable under Features without dominating Home. Feature gear reveals message notification preferences inline; Settings retains the same per-phone controls.

### Clipboard and Quick Paste Tray

Separate Share and History with two compact buttons and an 8 pt/dp gap, without a segmented track. Keep manual sharing available when automatic sharing is off. Put consent and collection toggles in Settings and Clipboard preferences, not in task content or the history list. Explain local persistence before history opt-in; pausing collection preserves saved items. Confirm clear/delete.

Quick Paste Tray is a compact, focused floating surface with search, horizontally scrollable clips, a focused item, multi-selection and optional full-text preview. Pin and delete remain visible without hover. Arrow keys move selection, Space previews, Return copies, Escape exits preview/search before closing. Preserve search focus, selected identity and horizontal scroll during updates. On copy failure, keep the tray open and explain recovery; closing the tray never implies cancellation of unrelated work.

### Settings and About

Mac Settings uses one column at compact widths and two columns when the detail area reaches 880 pt, centered within a 1120-pt maximum. Section shortcuts scroll only enough to reveal a hidden group and keep its heading visible. After scrolling, briefly highlight the destination group; shortcuts mark the selected section and raise label contrast on hover. Use lightly outlined groups for Appearance, Connection, Clipboard, Messages, File transfer, Now Playing and This device. Keep rows compact and descriptions short. Phone Settings uses concise native separated rows with minimal box framing. Both platforms share preference names and meaning. Clicking a row label activates its switch or destination; independent controls remain separate targets.

Feature-local preferences stay available from their own panels and update the same values as Settings. Appearance offers System, Light and Dark. Center Mac About within its 660-point reading width as the window expands. Preserve source, license, version and creator information; link Developer to GitHub, place secondary X and LinkedIn links in the developer row, reflowing below at narrow widths or large text sizes, and keep Support as a separate centered heart-only link. Phone social glyphs sit slightly toward their shared edge while retaining separate 48-dp targets. Do not add an extra About info button or warranty disclaimer.

### Menu-bar companion and notifications

The menu-bar companion contains an aniCe heading and overflow, device context, active playback/transfer, compact Send clipboard/Send files actions and a persistent Open aniCe footer. Hide idle transfer status. Show Send files only for a ready compatible target; active transfer replaces that action. Keep Settings, Manage devices and Quit in overflow. Use native Escape/outside-click behavior, restore focus and never cancel work on dismissal.

Notifications open the relevant existing destination and preserve the current task. Hide SMS text by default. Do not steal application focus. Use platform notification surfaces and concise, actionable text; do not announce every progress tick.

### Loading, empty, offline and error states

Keep layout stable with small placeholders during loading. Empty history explains how to start collection. An unpaired Home offers Pair a device. Offline states preserve drafts and local-only actions, identify the disconnected peer and offer reconnect. Permission-needed, unsupported, failed, canceled and uncertain states each name what happened and one useful next step. Preserve any draft, approved transfer progress or local history the actual product can retain. Do not show fake zero values or sample success in native UI.

## User journeys

1. **Connect/start:** First run → Pair device → QR or code → verify identity → approve on both devices → connected Home. Decline returns to pairing; permission requests remain contextual.
2. **Control media:** Home or menu bar → play/pause or seek → immediate local feedback → Now Playing for source/volume. Navigation preserves playback; disconnected controls explain reconnection.
3. **Transfer files:** Choose files → review list and named target → Send → progress → Completed. Incoming path is Offer → Review → Approve or Decline. Cancel is explicit and distinct from closing a surface.
4. **Message:** Messages → select thread → compose → select SIM beside Send → Send → Sending → Sent. Rejection and unknown outcome remain distinct; retain draft and avoid ambiguous resend prompts.
5. **Settings:** Open a feature's gear for local preferences, or Settings for app-wide groups → change preference → show immediate state → return to the same task. History opt-in explains local storage; automatic clipboard sharing consent remains explicit on both devices.

## Component behavior library

| Component | Default and loading | Success, warning, error and disabled |
| --- | --- | --- |
| Buttons | One primary action per decision; routine actions outlined/text; stable label while loading | Confirm near the action; error names recovery; disabled state has an adjacent reason |
| Sliders | Native track, visible value/time and large hit area | Keep requested preview while waiting; restore or explain failure; unsupported is not zero |
| Cards and lists | Boundaries only around coherent tasks; flat feature/settings rows; stable skeleton shape | State belongs to its row; full-row activation excludes star, menu and nested controls |
| Sheets and dialogs | Sheets for focused detail; dialogs for approval/destructive actions; focus enters and returns | Inline errors preserve input; Escape closes dialog, not background work; destructive copy names impact |
| Toggles and pickers | Native control, short label and optional necessary explanation | Consent is explicit; dependent choices show unavailable reason; retain saved choice where appropriate |
| Banners | Persistent only while a condition affects current task | State plus consequence and one relevant recovery action |
| Toasts | Brief local acknowledgement only | Never sole confirmation for a consequential send or transfer; persistent result remains in context |

## Motion and feedback

Direct controls respond immediately. Use roughly 120–160 ms for hover/selection and 180–220 ms for route/sheet transitions where motion clarifies change. Mac actions, menu triggers and native checkboxes use a faint hover tint bounded by their existing faces. Only unpadded text navigation and checkbox labels may extend feedback by three points; sidebar rows, icon buttons and ordinary button faces keep their original bounds; pressed buttons receive a stronger tint above their existing fill. Disclosure feedback stays around the arrow and label. Native menu items keep macOS highlighting. Settings section jumps raise label contrast and briefly focus the selected group. Do not add entrance cascades, pulsing connectivity or fake delay. Respect reduced motion and keep tasks interruptible. Android may use a light haptic for meaningful selection or completion, never every tap or slider tick. Mac relies on pointer, keyboard and native focus feedback. Always make state change visible without animation.

## Accessibility and validation targets

- Contrast: ordinary text ≥ 4.5:1; large text and meaningful control graphics ≥ 3:1 in both appearances, including selected/disabled states.
- Android touch targets: ≥ 48 × 48 dp. Visible phone button faces may be compact (about 32 dp) while preserving that interaction area. Mac retains visible keyboard focus and native hit areas.
- At 200% text scaling, labels and device names remain readable; Android bottom navigation switches to horizontally scrollable, fully labeled destinations. Stack peer sections and composer actions before truncating essential content.
- VoiceOver/TalkBack identifies action, target, state and result. Decorative icons are silent. Announce final state, not every progress update.
- Complete core journeys with keyboard only and logical focus. Sheets restore focus; ordinary navigation does not trap it. Test Android Back, Mac Escape and native popover dismissal.
- Pairing: ≥ 90% unassisted completion; median ≤ 60 seconds excluding OS prompts.
- File send: ≥ 95% task completion with ≤ 3 decisions before transfer starts; ≥ 90% understand accept/decline.
- SIM reply: ≥ 95% choose intended SIM; zero duplicate sends caused by ambiguous feedback in validation sessions.
- Find clipboard/message preferences: ≥ 90% success within 15 seconds. Return to prior feature in one navigation action.
- High activity: ≥ 90% identify a pending incoming file and current playback state within 5 seconds. Navigation never hides active work or its result.
- Feedback: immediate visible response within 100 ms; consequential results persist in task context.

Targets are validation gates, not claimed study results. Review both themes, compact and expanded widths, large text, long names, empty/offline/permission/error states, keyboard/focus, and screen readers. Validate native behavior in the actual app; browser preview only validates the concept.

## Platform consistency matrix

| Shared concept | Android | macOS |
| --- | --- | --- |
| Destination names and task state | Native bottom navigation; one focused conversation; system Back | Sidebar; split conversation when width permits; titlebar Back/Forward follows history |
| Device identity and connection | Native app bar and compact peer rows; This device from Devices or Settings opens the identity bottom sheet | aniCe-branded split titlebar and sidebar; This device from Devices or Settings opens the identity sheet |
| Actions and controls | Material switches, pickers and 48-dp targets; compact visual button faces | AppKit/SwiftUI controls, keyboard/focus behavior and compact outlined actions |
| Messages and SIM | Focused thread; keyboard Send; SIM left of Send | Conversation list and thread; Return sends, Shift-Return inserts newline; SIM left of Send |
| Feature preferences | Inline feature settings plus shared Settings values | Inline feature settings plus shared Settings values and Mac preference section jumps |
| Active work | Home and native notifications/lock-screen controls | Overview, menu-bar companion and notifications |
| Quick clipboard | Focused explicit-send surface where supported | Non-activating Quick Paste Tray with keyboard navigation |

## UX scorecard

| Dimension | Pass criterion | Risk | Mitigation |
| --- | --- | --- | --- |
| Continuity | All five core journeys complete; drafts and ongoing work survive navigation | Context loss | Keep the device and task target stable; preserve drafts and active work across history navigation |
| Hierarchy | Pending action found within 5 seconds | Busy Home | Show incoming approvals first, active work next and recent activity last; omit empty panels |
| Feedback | Visible response within 100 ms; consequential results persist in context | Feedback implies delivery too early | Distinguish Sending, Sent, Failed and Not confirmed; preserve recovery and avoid blind retries |
| Trust | Every send names its peer; every consent is explicit | Wrong target or hidden sharing | Name the recipient at review/send and show consent at the point of action |
| Native quality | Keyboard, Back, Escape and system surfaces behave as expected per platform | Web patterns forced into native UI | Use native controls, navigation and system surfaces |
| Accessibility | Contrast, touch target, scaling and screen-reader gates pass in both themes | Compact styling shrinks hit areas | Reduce visual chrome while preserving native interaction bounds |

## Interactive reference

Interactive visual concepts cover Mac, Android, menu bar, Quick Paste Tray, both appearances, everyday/high-activity use, first run, loading, offline, permission and interrupted-transfer states. Their identities, messages, playback, pairing, permissions and transfers are samples; they do not contact devices or send content. Drag/drop visuals do not grant a native drag/drop implementation. The mark and browser icons are placeholders; native icon systems remain required.

## Existing capability and platform constraints

Overview on Mac and Home on Android remain the initial destinations. Devices, Features, Favourites, Settings and About are separate sections. Mac exposes all six in its sidebar; Android uses five bottom destinations with a separate About route in the app bar. Do not put individual devices or Add device in the sidebar. Devices retains connection, LAN, pairing and trust management through the existing owners. Opening or closing a section never retires work by itself.

The overview is the daily workspace for device state, file sending and active playback. Devices manages connections. Features is a compact launcher for supported capabilities, not a second dashboard of full panels. Each feature opens a dedicated panel whose Back action returns to its entry destination: Overview, Features or Favourites. Now Playing keeps Playback setup in a disclosure; it has no separate Phone controls launcher. Find Device keeps its request and permission controls in its own panel. Feature rows have a trailing chevron and a separately labeled favourite action. Favourites has a Choose favourites action when empty; favouriting does not enable features or bypass capability/permission gates. Send files opens its own panel using existing file controls.

Primary peer lists show only secured peers while any are connected, otherwise trusted peers. Saved-device management remains available separately. Keep the selected device and operation target distinct: transfer panels name the authenticated peer and direction, and playback identifies its origin. A device picker changes presentation context, never silently reroutes an active job or playback command. Preserve other connected peers and their owners. The one-device case needs no picker.

## Full Mac window

Use a native resizable window. The titlebar keeps system traffic lights, then Back and Forward history controls on the left side of its split header; aniCe branding stays in the window header. Do not replace aniCe with the active page name. Page titles sit below the header at 20 pt. The sidebar has a small WORKSPACE label, Overview/Devices/Features/Favourites above, Settings/About at the bottom. Device context, readable connection state and a compact primary connection action lead the workspace. The overview uses one device/status row with immediately visible Auto connect and compact connection actions. It omits device lists, setup text and Manage devices. Devices owns flat peer rows with Auto connect, Bluetooth and LAN actions and Security and diagnostics. Add device opens pairing separately; trust management stays in a disclosure and This device opens a local identity sheet. Connection details opens a sheet containing transport controls, security fingerprint and collapsed Diagnostics. Security credentials remain selectable in their detail context; omit fingerprint prefixes from device summaries.

Sending files has one stable entry in the overview. An active transfer replaces the idle action with its approval/progress/result presentation. Local Mac playback remains optional and off by default for ambient workspace/companion panels. Opening Now Playing from Features explicitly presents its dedicated controls even when ambient display is off. Full playback and the compact activity share one owner.

Center workspace content within a readable maximum on wide windows. Overview activity uses one column below 720 pt of detail width and two aligned columns above it; never exceed two. Feature launchers use one column below 700 pt and two above it. Connection details uses a sheet.

Without a trusted Android device, show No devices paired yet and Pair a device. The companion directs pairing to the full window. Preserve access to implemented local playback and settings. Battery, charging and storage have no placeholder values: battery/charging can enter the device header after authenticated data support exists; storage remains omitted.

## Mac menu-bar companion

The companion is for checking a device and taking a quick action. Browsing and configuration belong in the full window.

- Use a monochrome template status-item glyph and a native anchored panel approximately 340–360 pt wide.
- Show compact device rows with a small native name and connection status inline, a contextual connection action when disconnected and a details route. Wrap long names rather than increasing the normal row height for short names. Connected peers appear first; when any are connected, other peers remain accessible through the full workspace.
- Show Send files only for the actual ready, compatible transfer target and hide it during preparation or an active/result transfer. Do not attach a global transfer command to an unrelated connected peer.
- Use the original companion hierarchy: compact aniCe heading with overflow, device header, then content separated by dividers between populated sections. Do not place filled activity cards inside the companion surface. Keep playback and transfer visible together without paging, page counters or swipe gestures. Keep incoming offers visible.
- Music has a Now playing heading and On this Mac origin. Keep artwork when available, title/artist, supported seek with elapsed/duration and balanced native transport buttons visible. Use restrained, softly rounded rectangular controls in the shared neutral action style. Full playback keeps the Player selector visible with Auto and advertised sources. The companion also shows it when multiple players exist; More playback controls reveals compact player volume; it does not hide ordinary seek controls. Missing artwork stays absent.
- Find Device remains in its feature panel. Clipboard opens its native text-sharing panel; battery and charging remain absent until their data and behavior exist. No disabled future-feature placeholders or permanent Quick actions heading.
- Send clipboard and Send files are compact labeled controls below current activity, wrapping vertically when needed. Send files names its ready target. The Open aniCe footer has a trailing arrow; Settings, Manage devices and Quit live in the header overflow. Modal pickers retain the companion and restore focus. Dismissal never means cancellation.
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

Use a native top app bar and five bottom destinations: Home, Devices, Features, Favourites and Settings. About opens from the app bar. Home contains device summaries, file sending and relevant playback. Devices uses separated native peer rows with status, automatic preference, LAN action and a security/diagnostics disclosure; avoid nested cards. This device remains a navigation row; This device and Add device are full-width rows at the end of Devices. Features and Favourites use concise full-width rows, not large tiles. Phone Home shows one compact device/status row with 8-dp additional vertical space above and below; automatic connection preferences stay in Devices. Keep the aniCe app-bar brand visible. Device lists, management, LAN actions and This device identity belong in Devices. Omit a redundant Connections heading below the Devices app bar.

Use native pickers, sheets, dialogs and scalable Material type. Home player volume uses one slim label/slider/value row while retaining its 48-dp interaction target and source-bound release behavior. Phone feature headings and device names use title-small roles, track titles use body-medium and supporting artist/origin text uses body-small; accessibility scaling remains native. Details stack at compact widths; do not force feature panels into equal-size tiles. Wider screens may use native navigation rails. Device names wrap; unknown facts stay absent. Full fingerprints live in selectable Connection details content. Automatic Bluetooth setup is directly accessible outside Connection details, preserving the existing permission/association flow. Incoming Find Device ringing and Stop remain native alert/notification behavior, independent of the Features launcher.

Back closes the local identity sheet, expanded details or a feature setup view, then nested pairing/discovery, then returns to the overview. Returning to the overview through navigation exits management without cancelling its owner. Successful pairing returns to the overview after authenticated trust activation and cleanup. Media notification taps open the dedicated Now Playing panel.

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

Native implementation must establish clipboard access, direction, loop prevention and private-content handling before enabling automatic sharing. Native Clipboard v1 uses direct delivery, manual Send and one per-credential preference for automatic sending and receiving. In Share, show metadata before explicit Reveal. Keep native Share and History views. Send clipboard and Send files are one-shot actions, separate from automatic sharing; use compact native bordered buttons with a symbol and label. Android preserves 48-dp targets, 8-dp corners and neutral semantic ink. Mac uses small native bordered buttons, including direct actions in the companion. Share shows device context, Send clipboard and current status; its gear opens automatic-sharing preferences in place. More options holds inspection, Reveal and manual paste, with details under How sharing works. History is a device-local opt-in with two-line rows, origin, timestamp, Copy/Send/Delete and confirmed Clear all. Preferences are shared between Settings and the inline Clipboard settings, default off and explain local persistence before enabling. Turning history off pauses collection but preserves saved items across restart, Forget device and Reset identity. Clear/Delete removes items; count limits bound retention. Both platforms offer 20/50/100-item capacities and 4-pt/dp horizontal spacing. History groups entries by local date, newest first, with saved count, Clear all, origin/time and labeled row actions. History remains available without a peer. Android provides a compact Send to Mac panel for selected text and shared text/URLs; it does not open the full workspace. The browser sample never accesses the clipboard.

Android 10+ restricts clipboard reading to the app that currently has input focus or the default input method editor (IME) ([clipboard privacy restrictions](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data)). For aniCe's ordinary app, automatic reading must be limited to periods when it has focus; do not implement continuous background clipboard monitoring or assume a foreground service grants access. The Send to Mac Quick Settings tile opens a focused explicit-send panel. It reads once after actual focus, displays metadata and requires Send, preserving sensitive-marker confirmation. That focus grants manual read access without enabling automatic sharing or history observation. The tile is not a clipboard-access exemption; its system-bound service never reads the clipboard or starts connections. Do not introduce an IME or sandbox bypass merely to enable clipboard sharing.

## Panel and interaction rules

A panel groups one task. It earns its boundary through content and controls, not an icon plus marketing sentence. Size panels to their task; do not pad every panel to the same height or put a card inside another card.

Provide an overview panel, full view or quick action only when each serves a distinct task. Reuse device context and state across them. Each panel has a title, source/destination when relevant, task content, one main action and secondary controls.

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

## Transport connection details

Each device has one readiness-based summary and a compact primary Bluetooth action. Only secured transports appear in Connected; pending/failed secondary channels retain separate feedback. Device-level Disconnect closes both owners; transport-specific actions close only their channel. LAN retains manual controls alongside the opt-in automatic policy. Mac Connect opens bounded admission and waits for the phone.

Ordinary buttons, navigation titles and close symbols use neutral primary/secondary ink. Automatic checkmarks use the shared neutral action ink; state colours remain separate. Android uses native outlined/text controls with modest corners and reduced visual padding. Connection action faces can be about 32 dp high; native Material interaction bounds remain 48 dp and scalable text may increase visual height. Android automatic preference is observable application state presented outside Connection details as a compact native checkbox in one accessible 48-dp row. The close symbol is 18 dp inside its native 48-dp icon-button target.

Android Devices presents Bluetooth and Local network as direct compact rows beneath the device name, readiness and automatic preference. Security and diagnostics expands inline from a full-width disclosure with a chevron and accessible expansion state. Device-level Disconnect remains in the expanded details. System Back, its labelled close icon or Connection details action collapses presentation without retiring work. Diagnostics is a full-width disclosure with accessibility state; it owns the association-settings route, connection checks/counters, Debug automatic-service events, discovery compatibility and LAN lifetime information. Debug service events are a separate collapsed disclosure, reset whenever Diagnostics opens. Association settings uses the native RTL-aware Back icon and contains no duplicate diagnostics. Opening Bluetooth discovery preserves both transports. Scan suspends/retires Bluetooth only; automatic ownership resumes after discovery cleanup. LAN remains active and device-level Disconnect still closes both transports. Trusted-device management shows full names and separate confirmed Forget actions; clicking a device name expands its selectable full fingerprint. Phone trusted-device rows include a Security fingerprint subtitle and a mirrored chevron indicating expansion. Disclosure labels activate their entire row on both platforms. Android Settings uses the title aniCe Settings. Device summaries omit fingerprints; security details retain the full credential. LAN progress reports finding the Mac while bounded discovery and authentication overlap.

The companion has bounded 520-point scrolling and a persistent footer. A compact Send files row names the ready target. Transfer and playback use flat sections with visible supported seek, secondary playback controls and modal picker focus restoration.

Manage devices preserves existing sessions while browsing; pairing/discovery still acquires exclusive radio access. Pairing offers one Connect automatically choice after pairing for Bluetooth and LAN. After mutual trust activation and guarded native cleanup, both apps return to the overview and start fresh Bluetooth work. Android first enable requires its native permission/association dialogs; remembered setup resumes inline without a settings-page flash. Android disable releases automatic/background ownership but retains eligible secured foreground work as manual; background/lock cleanup and hard limits remain. Automatic setup remains subject to platform/build availability.

Expanded Mac trusted-device lists use flat peer rows without nested cards. This device uses a compact name/platform header. The phone identity sheet uses one horizontal content inset, compact vertical spacing and caption-sized monospaced identity values; copy controls retain native touch targets. Android shows a title-medium name, 28-dp phone symbol and a shared 24-dp horizontal sheet inset, with RTL-aware Back. Copy actions sit beside identity labels. Edit name uses a native dialog accepting 1–64 trimmed Unicode code points; atomic writes preserve device ID/key material and recover without replacing identity after failure. Reset remains under Advanced with confirmation. Its entry control uses compact neutral outlined styling; destructive color belongs to the final confirmation action. Existing authenticated snapshots do not update display names until a subsequent identity exchange.

## Appearance and local identity

Settings contains This device, with editable name, identity details and confirmed reset, while the separate About section contains aniCe, the installed version, “Connect your Mac and Android.”, separate source-code and GPL-3.0-or-later license links, and a Developer link to GitHub labeled @anisharyal09. Both platforms place X and LinkedIn profile links beside the Developer credit. About ends with a horizontally centered heart-only support link to https://anisharyal09.com.np/support?from=anice, using a subdued outline heart and the accessible label Support aniCe. Advanced stays collapsed. Navigation and appearance never cancel transports.

The Android LAN background timeout defaults to Never; explicitly saved timeout choices are preserved. Ordinary BLE feature traffic initiates LAN when missing, subject to both preferences, eligibility and local Disconnect pause.

Appearance is saved locally as System, Light or Dark, defaulting to System. Android applies it to the main app and association settings. Mac labels it Window appearance, uses a native menu picker and applies it only to the main window. System resolves its scheme from observed application appearance independently of the window. The resolved preference applies through SwiftUI’s presentation-level preferred color scheme to both the window and connection-details sheet, including native controls; the sheet uses the matching semantic surface and text colors. Later macOS appearance changes update System mode without changing a forced Light or Dark preference. The companion, popover and native context menus follow macOS appearance and resolve their colors independently. Companion deep-links update the shared destination and peer context before restoring and activating the main window, including when it is already on Settings.

## Now Playing

Navigation keeps Overview/Home, Devices, Features, Favourites and Settings, with About as its own section. Features launches each capability in its own panel. Playback setup stays inside Now Playing. Compact music names its playback origin and keeps supported seek visible. More playback controls reveals secondary controls in place. Playback buttons use native icons and accessible labels. Ambient Mac playback remains optional and off by default; explicit Now Playing access remains available. Phone subscriptions are independent. Genuine playback is required for ambient cards, with paused resumable sessions retained for a 90-second grace period.

Full playback presents available artwork/title/artist/player/state, Auto/player picker, locally advancing elapsed/duration and advertised controls. Missing metadata stays absent; unsupported actions are disabled. Unknown duration or unsupported seek omits the slider. Scrubbing captures source/revision, sends once on release and cancels on replacement. Android slider and elapsed label share atomic dragging, pending preview and authoritative state. Keep the thin track, small thumb, aligned monospaced labels and a 48-dp accessible interaction area; acknowledgement does not disable scrubbing or confirm position. Supported selected-player volume uses an integer 0–100 slider and one command on release. Slider-bearing activities have no swipe gesture. Hidden/paused/disconnected presentation stops progress animation. Permission-needed feedback directs Android to the explicit Mac permission action.

Artwork has a reserved placeholder on both platforms so asynchronous delivery does not shift track text. Clickable activity headings include a forward chevron. Mac playback controls show hover and pressed feedback within their existing shapes. Artwork is in-memory and LAN-only; Bluetooth supports metadata and advertised controls. Android presents supported playback through native MediaSession/MediaStyle notifications and lock-screen controls on a silent channel. Tapping opens Now Playing. Playing restores compact surfaces; pausing starts a monotonic 90-second grace period that metadata updates cannot extend. Expiry hides compact cards and system presentation while explicitly opened Now Playing retains paused controls. Background presentation requires existing companion ownership and an already-secured BLE channel; it does not request artwork or progress updates. A separate media foreground service remains excluded. See [Now Playing](../features/NOW_PLAYING.md) for capability details.

Features explains player-control discovery, unsupported actions, permission requirements and temporary unavailability. Refresh preserves selection and never prompts. Player-volume previews retain the requested value through asynchronous execution until a matching sample or readable failure/timeout feedback. Unsupported browser/wrapper player volume remains distinct from Mac output volume.

Phone volume buttons control separately advertised Mac output volume while genuine compact playback is active. Full detail labels this Mac output control and its current percentage/availability; the Player volume slider retains its selected-player meaning. Device replacement/retirement clears preview and unsent key intents, without volume-command replay. Unsupported output control preserves foreground Android key routing.

## Find Device

Features presents a labeled Find Device panel opening peer-scoped request actions, local permission setup and notification settings. The panel shows connected peers while any are connected, falling back to saved peers with Devices connection guidance when none are connected; connected peers without a capability advertisement show that fact instead of being described as unsupported. Empty trust inventories show a pairing instruction. Device summaries and the companion omit Find Device. Pending feedback names its peer and distinguishes OS submission from display or sound, with unsupported and blocked states kept separate from connection readiness. Incoming requests never open permission prompts or take application focus. Native alerts localize the authenticated peer name. Mac retains notification Dismiss. Android rings at its current alarm volume for at most sixty seconds, exposes Stop ringing in a foreground notification, and shows a native alert dialog while the app is open. Dialog dismissal and Stop end playback; no background activity or lock-screen overlay is forced. Explain that Silent/Vibrate differs from muted alarm volume and DND.

Find Device permission actions wrap on narrow Android layouts and retain 48-dp touch targets. Mac permission feedback wraps vertically; peer actions retain their intrinsic width beside wrapping device names.

## Messages (SMS relay)

Features presents one labeled Messages panel per platform, scoped to the connected selected phone. Android opens with permission setup when any of RECEIVE_SMS, READ_SMS or SEND_SMS is missing: a compact block names the missing capabilities, offers **Allow SMS access**, and links to App info with the **Allow restricted settings** explanation after a permanent denial. The block disappears on the first full grant; the panel status then reads **SMS access granted** until a Mac link reports the relay instead, and a revoked permission restores the block naming only that capability. Settings → Messages is one line naming what is still needed while a permission is missing, so access is requested in one place only; the first full grant removes that section too. The Mac shows connect guidance instead of an empty conversation list while no phone is connected.

Mac notifications name the address as the title, keep message text hidden until **Show message text in notifications** is enabled for that phone in Settings → Messages, and keep the inline Reply action in both cases. Group banners by normalized address. Settings → Messages lists one collapsed row per phone behind its clickable name label, which itself reports **Notifications on/off**, sound and text-preview state; expanding a row shows that phone's **Notifications** switch, a **Play sound** switch (both on by default, sound unavailable while notifications are off) and the text-preview checkbox, and the gear on the right of the Messages panel's search or conversation row expands the same three switches in place under that row, so the controls never float outside the window. Switching notifications off suppresses that phone's banners, sounds and failure alerts while the panel keeps counting unread rows and relay activity. A failed or unconfirmed reply posts a separate **Message to <address> failed to send** alert; the composer shows the same failure inline. Desktop notifications are cleared on quit rather than left in Notification Center.

Conversations keep the phone's provider order (newest first) with address, one-line snippet, time and an unread count that is a provider value, never a read-state control; the Mac list paints 15 cards first and continues from the page cursor as its last card appears, so the panel never blocks on the full phone list, and it shows **Load older conversations** while another page exists and none is loading, so a dropped automatic request is one click away from continuing. Opening a conversation shows its address, history in chronological reading order with direction and time, and a bottom composer with its byte counter. Keep **Show older messages** above the history only while another page exists; the first page carries ten rows. Pressing Send paints the outgoing reply at once as a provisional row stamped at the submit second and marked **Sending**; the phone's answer settles its identity and provider time, or takes the row back out when the reply was rejected or unconfirmed. Live receipts and sends retain local observation order, including after provider refreshes, so carrier clock differences cannot move an answer below its send. Untouched provider history keeps provider chronology. Rows group under a day header, and a conversation whose messages arrived on two different known subscriptions labels each such row with a compact SIM chip beside direction and time (text only, no color alone; outgoing rows on the telephone default read **Phone default**); a conversation with one known origin shows no chips. Row metadata (direction, time, SIM chip, unread) is set in caption size and secondary color so the message body stays the largest text on the row, opening a conversation puts the cursor in the draft, and on the Mac **Return** or **Command-Return** sends while **Shift-Return** keeps the newline, with the SIM control directly left of the Send button; Android's composer sends from the keyboard's send key through the same path as its Send button; the SIM selector stays left and Send SMS is anchored at the far-right edge of their shared row. The counter turns to the error color past the 24,576-byte bound and a soft warning appears past roughly 1,000 characters because carriers reject very long or UCS-2 multi-part sends. Long bodies and addresses wrap; row bodies are selectable on the Mac.

Keep request, permission and unsupported states separate and truthful: an empty result, a disabled permission, an unavailable provider and a connected-but-capable-pending phone never share one message. Report skipped unreadable rows as a count instead of silently dropping them, and do not describe the Mac view as a message store: history, unread counts and read state live on the phone, and the Mac clears its copy when the last channel retires.

Mac Messages keeps routine loading/history status out of the conversation header; permission, failure and uncertain-send feedback stays visible. Connection counters live under the feature settings disclosure. Date separators carry the day; bubble metadata keeps time, pending state and mixed-SIM context. The composer shows byte capacity only near its limit. Settings section shortcuts include File transfer, Now Playing and This device; all targets participate in layout before scrolling.
