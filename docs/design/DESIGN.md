# aniCe design direction

Version 0.1 — current design direction. Evolve it through deliberate, documented changes as the product develops.

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
- Reference text sizes: Mac body 13–14 pt, secondary 12–13 pt, section title 14–16 pt, page title 24–28 pt. Android body 14–16 sp and supporting text 12–14 sp, mapped to Material roles.
- Use regular and medium weights for most content. Semibold can establish a heading. Avoid oversized title hierarchies, decorative display fonts in controls, or monospace as a technical costume.
- Use one native icon system per platform: SF Symbols on Mac and Material Symbols on Android. The browser concepts use Lucide only as a stand-in. Icons supplement essential labels.
- Spacing scale: 4, 8, 12, 16, 24, 32. Keep related content close and separate tasks with more space. Typical panel padding is 16–20, page padding 24–32 on Mac and 16–24 on Android.
- Reference radii: Mac small controls 6–8, content panels 10–12, floating companion 12; Android buttons use the small Material shape role (8-dp corners), with roughly 16 for grouped panels. Do not impose one universal rounded shape on everything.
- Borders and tonal surfaces provide grouping. Soft shadows belong mainly to floating surfaces. No colored halos, gradient text, decorative glass, bouncing panels, or pulsing connectivity.
- Require at least 4.5:1 contrast for ordinary text and 3:1 for large text and meaningful control graphics. Preserve visible native focus indicators and screen-reader labels; color must never be the only state signal.

## Full Mac window

Without a trusted Android device, show pairing actions and omit the trusted-session connection section, empty trusted-device panel, and discovery compatibility disclosure. The companion directs pairing to the main window. Keep active connection controls visible until the operation ends; cached presentation records do not authorize session admission.

Use a familiar resizable window with a toolbar and sidebar. Sidebar destinations select pages; the selected device scopes the content. Keep these two concepts visually distinct.

The overview hierarchy is:

1. Selected device and readable connection/trust state.
2. A concise device information strip showing battery/charging and connection facts. Omit storage for now; leave the space open instead of adding replacement metrics.
3. A live-activity panel and a few pinned functional panels with useful content and direct controls.
4. A quiet route to the broader feature workspace and activity.

Home, Devices, Features and Settings form the implemented navigation. Home contains compact trusted-device rows; Devices owns connection, pairing and diagnostic controls; Settings owns local identity and appearance. Feature content and activity history are added only when implemented, without empty destinations or placeholder panels.

Use one or two functional columns depending on available window width and text size. Detailed feature work opens its own content view. Smaller windows collapse navigation using native sidebar controls; they do not remove access to it. Preserve the selected device when moving between pages.

Customization is explicit: pin/unpin and, when implemented, accessible reorder controls. Removing a panel from the overview does not disable the feature or hide its availability in Features. Ship a sensible default arrangement rather than making setup mandatory.

## Mac menu-bar companion

The companion is for checking the device and taking one quick action. Browsing, configuration, and sustained work belong in the full window.

- Use a monochrome template status-item glyph with a system-managed selection appearance.
- Start with an approximately 340–360 pt wide anchored panel. Its height follows actual content, with screen-boundary handling delegated to native presentation.
- Show the selected device, connection state, and one concise device fact when available.
- Show one live-activity panel and up to three pinned labeled quick actions. Reuse the activity pattern from the main app, with content adapted to the smaller surface. Empty or irrelevant activities do not reserve blank space.
- Show an active operation only while it is relevant. Explain progress or interruption; never make dismissal mean cancellation.
- Keep **Open aniCe** visible. Settings and Quit belong in a standard overflow menu. Multi-step tasks open the appropriate full-window view.
- Share device selection, availability, operation state, and preferences with the full app. Do not create a separate menu capability model.
- Clicking the status item toggles presentation; Escape and outside click dismiss it. Focus enters the panel and returns to the status item on dismissal. Actions must work by keyboard and VoiceOver.
- Opening the app focuses or creates its window and preserves device context. Closing that window does not stop background work when the companion is enabled. Explicit Quit has separate semantics.
- Background updates never open the panel or steal focus. Do not claim a shortcut in the interface before it has been implemented.

The concept illustrates an interactive panel. Validate its final native presentation against the selected minimum macOS version; the browser sample does not prove native behavior.

The companion uses an AppKit status item to distinguish left-click panel presentation from a right-click native menu. A transient `NSPopover` hosts the same SwiftUI content and shared owners; native sizing follows content changes. Escape and opening the main app explicitly close presentation without cancelling connections. Check focus, outside-click dismissal, keyboard access and VoiceOver on supported macOS versions. [AppKit popover behavior](https://developer.apple.com/documentation/appkit/nspopover).

## Android

Completed pairing returns to Home after transport cleanup and a matching active trust record is visible for the current local identity. Mutual approval remains explicit. Pairing actions use Scan QR code, Pair using code and Approve pairing; they do not label trust establishment as a secured session. Manage devices shows saved devices first and exposes Pair another Mac. Merely opening management does not cancel a session or suspend automatic ownership; starting pairing/discovery still uses exclusive-radio cleanup. Each Home entry has a compact primary connection button, a direct secondary details action and an available automatic-Bluetooth switch.

Use a native top app bar, a visible device context, and Material navigation. Home, Devices, Features and Settings share the same concepts as Mac, using a bottom navigation bar on phones. Keep battery/charging and connection facts in the device summary; omit storage for now.

Detailed panels stack on compact phones. Use a compact grid only for short actions or genuinely short content; do not shrink text or controls to force a desktop layout into two columns. Larger windows can use navigation rails and more columns when they improve the task.

Use native pickers, sheets, switches, and dialogs. Honor system Back, predictive Back where supported, window insets, text scaling, and reduced motion. Detailed or sustained work gets a screen; a brief contextual task may use a bottom sheet.

Plan for edge-to-edge rendering. Android 15 enforces it for apps targeting API 35 on Android 15 devices ([behavior changes](https://developer.android.com/about/versions/15/behavior-changes-15)). In Compose, protect top-bar, bottom-navigation, and other interactive content using `WindowInsets.safeDrawing` or the corresponding Material component inset handling ([Compose cutout guidance](https://developer.android.com/develop/ui/compose/system/cutouts)). Apply and consume insets once rather than doubling Scaffold and child padding. Test cutouts, gesture navigation, three-button navigation, and the on-screen keyboard; backgrounds may extend behind system bars while controls remain safe.

Every interactive target is at least 48 × 48 dp ([Android accessibility guidance](https://developer.android.com/guide/topics/ui/accessibility/views/apps-views)). Leave enough separation between controls. The drawn icon can remain smaller than its hit region. The static aniCe palette is the starting identity; optional Android Dynamic Color is a later explicit design choice, not an automatic replacement of this baseline.

The implemented Devices overview starts below the app bar as a flat device list. Each entry shows the full device name, one connection line with an eight-hex-digit fingerprint prefix and Connect, Cancel, Retry or Disconnect. Names wrap without ellipsis. Use spacing and alignment to group the entry; separate multiple devices with a quiet divider. Do not add a bordered card, repeated security copy or a stack of full-width setup actions to this list. Keep it scrollable and bound content width to 640 dp.

Manage devices opens the existing pairing and trust-management flow. Each device entry has a direct Connection details action; the discovery compatibility check and connection-check controls live inside its collapsed Diagnostics section. Feedback stays beside its device or transport. Connection-window instructions appear only when disconnected. The short fingerprint identifies a list entry; full credential matching remains the authentication boundary. Mac target selection lives in connection details, freezes while either transport allows connections, and never gates Connect on asynchronously loaded display records. Preserve system typography, including configured font and scaling preferences. Idle expiry, peer closure and trust failure have distinct messages; normal session endings are disconnected states.

The Devices overview exposes Connect automatically; connection details retains the existing setup settings route. Automatic nearby connection uses one device-level native checkbox, with system setup on first enable or permission/association repair; build/platform gates remain enforced. Disconnect pauses retries; enabling or explicit Connect resumes remembered setup. Waiting nearby and Waiting for Bluetooth are quiet statuses, while trust, permission and setup failures explain the required correction. Mac shares one Connect automatically preference across Devices and the companion’s contextual connection state. Native service event logs remain Debug-only; background updates never open windows or take focus.

Connection settings show only the displayed Mac's enabled state, native association setup and reset action. Checks, counters and Debug service events live in Connection details → Diagnostics. Another Mac's saved setup keeps this checkbox off; enabling it explicitly replaces that setup through the native chooser. Device ID and full fingerprint scope these controls; display-name changes do not change their relationship.

## Live activities

One home panel hosts current sessions, active operations, and brief recent results. Now Playing is one possible activity rather than a permanent definition of the panel. This pattern is shared by Mac, Android, and the compact menu-bar companion.

- Show one activity at a time with its own useful content and controls. Provide labeled page indicators and previous/next controls. Disable activity swiping for the entire active card whenever it contains an interactive horizontal slider, including Now Playing's seek and volume controls. Use arrows or indicators on that card instead. On other cards, support horizontal swipe only when it does not conflict with scrolling or system navigation.
- Indicators represent the activities actually present. Do not reserve three slots or show an empty activity just to fill a carousel. Hide pagination for a single item.
- Never auto-rotate. Preserve the selected activity during interaction. New events may update the queue without moving a control under an active pointer or finger.
- Active items persist while their operation is relevant. Recent results are brief and dismissible, then remain in Activity history where appropriate. Exact retention follows the operation specification.
- The same selected device owns the activity set across surfaces. Keep the target and direction readable inside each item.
- Do not put essential incoming events or urgent recovery only on a hidden page; expose a visible attention affordance and use appropriate native event presentation when implemented.
- A future capability may contribute an activity only after support and behavior are established. Call-related integrations remain feasibility questions; this design does not establish call forwarding as supported.

## Clipboard preference

Settings presents **Automatic clipboard sharing** as a toggle. It is off by default: off means manual sharing, with an explicit Send action. On means automatic sharing for the selected trusted-device relationship when the platform and permissions support it.

Keep the choice scoped to the paired device and synchronized across its app surfaces. Reflect the current mode in the clipboard panel and quick action; turning automatic sharing off immediately returns the interface to manual sharing. Do not label a requested mode as active if a required permission or platform capability is unavailable. Show the reason and available manual route.

Native implementation must establish clipboard access, direction, loop prevention, and private-content handling before enabling automatic sharing. The browser sample changes only its sample preference and labels; it never accesses the clipboard.

Android 10+ restricts clipboard reading to the app that currently has input focus or the default input method editor (IME) ([clipboard privacy restrictions](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data)). For aniCe's ordinary app, automatic reading must be limited to periods when it has focus; do not implement continuous background clipboard monitoring or assume a foreground service grants access. A quick-settings tile or notification action may provide an entry to a focused, explicit sharing flow, but is not itself a clipboard-access exemption. Validate that flow on supported Android versions before promising it. Do not introduce an IME or sandbox bypass merely to enable clipboard sharing.

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
8. Preserve the live-activity pattern and automatic/manual clipboard preference. Do not reintroduce storage into the device summary or invent replacement metrics without a product requirement.
9. Disable card swiping on slider-bearing activities, handle Android safe drawing insets without duplicate padding, and verify native menu focus/dismissal before selecting any AppKit fallback.

Review meaningful UI changes in both themes, compact/expanded widths, large text, long device names, empty/offline/permission states, keyboard/focus order, and screen-reader labels. Test native Android touch targets and Back behavior, and native Mac menu focus/dismissal separately when implemented. Use bounded review passes and fix discovered issues together.

## Design references

- [Impeccable by Paul Bakaus](https://github.com/pbakaus/impeccable): primary design guidance, especially Operate, craft-floor, and native adaptation principles.
- [Design skills by Emil Kowalski](https://github.com/emilkowalski/skills): supplemental Apple-style interaction and design-engineering guidance. Native platform rules take precedence over its web implementation examples.

The ignored local self prototyped images (designed by anisharyal09) under `for-me/` were used as design references. They are not runtime dependencies and do not need to be published with aniCe. This guide captures the project-specific rules; the upstream links remain accessible to contributors.

## Transport connection details

Each device has one readiness-based summary and a compact primary Bluetooth action. Only secured transports appear in Connected; pending/failed secondary channels retain separate feedback. Device-level Disconnect closes both owners; transport-specific actions close only their channel. LAN stays manual. Mac Connect opens bounded admission and waits for the phone.

Ordinary buttons, navigation titles and close symbols use neutral primary/secondary ink. Automatic checkmarks alone retain the shared accent (light #355B70, dark #A7C5D6); state colours remain separate. Android uses native outlined/text controls with 8-dp corners, 10×4-dp standard content padding and 14×2-dp connection-action padding. Connection action visuals have a 32-dp minimum height; native Material interaction bounds remain 48 dp and scalable text may increase visual height. Android automatic preference is observable application state presented as a compact native checkbox in one accessible 48-dp row. The close symbol is 18 dp inside its native 48-dp icon-button target.

Android Devices expands compact transport rows inline from a full-width Connection details disclosure with a chevron and accessible expansion state. The primary connection action remains separate. System Back, its labelled close icon or Connection details action collapses presentation without retiring work. Diagnostics is a full-width disclosure with accessibility state; it owns the association-settings route, connection checks/counters, Debug automatic-service events, discovery compatibility and LAN lifetime information. Debug service events are a separate collapsed disclosure, reset whenever Diagnostics opens. Association settings uses the native RTL-aware Back icon and contains no duplicate diagnostics. Opening Bluetooth discovery preserves both transports. Scan suspends/retires Bluetooth only; automatic ownership resumes after discovery cleanup. LAN remains active and device-level Disconnect still closes both transports. Trusted-device panels show full names, Forget and selectable full fingerprints; Device summaries retain short prefixes. LAN progress identifies the existing 15-second browse before resolution/authentication.

Mac Devices sections fill the available width. Main-window connection details uses a sheet. The approximately 350-point companion shows compact device summaries and one contextual connection action; its trailing device arrow opens Devices in the main window. Longer device lists use bounded 520-point scrolling with a persistent footer. New pairing opens the main window. The AppKit status item/popover shares the existing owners: left-click presents, right-click/Control-click opens native window routes and Quit. Escape and outside click dismiss presentation. Physical persistence, sizing, focus and VoiceOver acceptance remain pending.

Manage devices preserves existing sessions while browsing; pairing/discovery still acquires exclusive radio access. Pairing offers automatic Bluetooth before approval. After mutual trust activation and guarded native cleanup, both apps return to the overview and start fresh Bluetooth work. Android first enable requires its native permission/association dialogs; remembered setup resumes inline without a settings-page flash. Android disable releases automatic/background ownership but retains eligible secured foreground work as manual; background/lock cleanup and hard limits remain. Automatic setup remains subject to platform/build availability.

This device uses a compact name/platform header. Android shows a title-medium name, 28-dp phone symbol and 12-dp panel padding, with RTL-aware Back. Copy actions sit beside identity labels. Edit name uses a native dialog accepting 1–64 trimmed Unicode code points; atomic writes preserve device ID/key material and recover without replacing identity after failure. Reset remains under Advanced with confirmation. Its entry control uses compact neutral outlined styling; destructive color belongs to the final confirmation action. Existing authenticated snapshots do not update display names until a subsequent identity exchange.

## Application structure and appearance

Home, Devices, Features and Settings are permanent native destinations: a Mac sidebar and Android bottom navigation. Home is the initial destination. The Mac sidebar carries a compact aniCe heading; Android uses a title-medium aniCe top-bar title on Home and Devices, and aniCe Settings on Settings; nested routes retain their task titles. Devices uses a 12-dp top inset above its section label. Android top bars have a 48-dp content height at standard text size and grow for scaled text; status-bar insets and Back touch bounds remain native. Mac keeps its semantic toolbar surface and content divider visible on all four destinations, including unscrolled pages. Each paired-device row contains a wrapping name, readiness-based connection summary, contextual Bluetooth action and trailing arrow to Devices. Clicking the name/status area also opens Devices; the connection action remains independent. No feature panels or activity history appear before their underlying capabilities exist. Without trusted devices, Home shows “No devices paired yet” and “Pair a device”; the button opens the Devices pairing entry without starting radio work.

Devices contains the existing connection controls, automatic Bluetooth preference, transport details, pairing, trust management and collapsed Diagnostics. Settings contains a compact, clickable This device entry on both platforms; its nested screen exposes editable local name, identity details and confirmed reset. Name editing opens explicitly and Advanced remains collapsed until selected. Navigation retains peer context and nested device routes; it does not invoke transport cancellation. Android Back closes nested content, then returns to Home. Successful pairing returns to Home through the existing authenticated handoff.

Appearance is saved locally as System, Light or Dark, defaulting to System. Android applies it to the main app and association settings. Mac labels it Window appearance, uses a native menu picker and applies it only to the main window. System resolves its scheme from observed application appearance independently of the window. The resolved preference applies through SwiftUI’s presentation-level preferred color scheme to both the window and connection-details sheet, including native controls; the sheet uses the matching semantic surface and text colors. Later macOS appearance changes update System mode without changing a forced Light or Dark preference. The companion, popover and native context menus follow macOS appearance and resolve their colors independently. Companion deep-links update the shared destination and peer context before restoring and activating the main window, including when it is already on Settings.

Native focus, screen-reader operation, opposite window/system appearances, large text and physical connection continuity require interactive verification; hosted/unit checks do not establish these results.

## Now Playing

Navigation order is Home, Devices, Features, Settings. Mac Features lists the implemented Now Playing capability under Phone controls, with active-subscription and explicit permission presentation. Android Features groups its Now Playing workspace under Mac controls. No future placeholder inventory or sharing toggle exists. Home keeps device summaries above activities; the companion uses the same order. Playback buttons use native icon controls with accessible action labels. Compact cards omit repeated device and Playing/Paused text; full Android detail names its originating Mac. Home exposes Auto/player selection alongside all supported controls. Mac local playback is optional: Settings → Show Now Playing on this Mac is off by default and controls Home/companion presentation only. Phone subscriptions remain independent. Enabled Mac surfaces and Android Home show a compact activity only for genuine playback, with paused resumable sessions retained for a 90-second grace period. Companion detail opens Phone controls. Android labels the originating authenticated Mac.

Full playback presents available artwork/title/artist/player/state, Auto/player picker, locally advancing elapsed/duration and advertised controls. Missing metadata stays absent; unsupported actions are disabled. Unknown duration or unsupported seek omits the slider. Scrubbing captures source/revision, sends once on release and cancels on replacement. Android slider and elapsed label share atomic dragging, pending preview and authoritative state. Keep the thin track, small thumb, aligned monospaced labels and a 48-dp accessible interaction area; acknowledgement does not disable scrubbing or confirm position. Supported selected-player volume uses an integer 0–100 slider and one command on release. Slider-bearing activities have no swipe gesture. Hidden/paused/disconnected presentation stops progress animation. Permission-needed feedback directs Android to the explicit Mac permission action.

Artwork is in-memory and LAN-only; Bluetooth still supports metadata and advertised controls. Native palettes, accessible labels, wrapping text and native touch/focus bounds remain shared. Android presents supported playback through native MediaSession/MediaStyle notification and lock-screen controls, on a silent channel. Tapping opens Features → Now Playing. Playing restores compact surfaces; pausing starts one monotonic 90-second grace period that metadata updates cannot extend. Expiry hides compact cards and system presentation while Features retains current paused controls. Background presentation requires existing valid companion ownership and an already-secured BLE channel, with no artwork or progress polling. A separate media foreground service remains excluded. See [Now Playing](../features/NOW_PLAYING.md) for acceptance status.

Features explains player-control discovery, unsupported actions, permission requirements and temporary unavailability. Refresh preserves selection and never prompts. Player-volume previews retain the requested value through asynchronous execution until a matching sample or readable failure/timeout feedback. Unsupported browser/wrapper player volume remains distinct from Mac output volume.

Phone volume buttons control separately advertised Mac output volume while genuine compact playback is active. Full detail labels this Mac output control and its current percentage/availability; the Player volume slider retains its selected-player meaning. Device replacement/retirement clears preview and unsent key intents, without volume-command replay. Unsupported output control preserves foreground Android key routing.

## Find Device

Connected trusted peers advertising Find Device expose an explicit native action near their device summary; the Mac companion shares the same owner. Pending feedback names its peer and distinguishes OS submission from display or sound. Features provides local permission setup and notification settings, with unsupported and blocked states kept separate from connection readiness. Incoming requests never open permission prompts or take application focus. Native alerts localize the authenticated peer name. Mac retains notification Dismiss. Android rings at its current alarm volume for at most sixty seconds, exposes Stop ringing in a foreground notification, and shows a native alert dialog while the app is open. Dialog dismissal and Stop end playback; no background activity or lock-screen overlay is forced. Explain that Silent/Vibrate differs from muted alarm volume and DND.
