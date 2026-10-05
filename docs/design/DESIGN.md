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
| Background | `#F4F3EF` | `#191E22` |
| Content surface | `#FFFDF9` | `#242B31` |
| Sidebar / secondary surface | `#EAEAE4` | `#20272D` |
| Primary text | `#262F35` | `#EDF0F1` |
| Secondary text | `#626E76` | `#ADB8BF` |
| Separator / outline | `#DCE0DF` | `#3C4850` |
| Primary action / selection ink | `#355B70` | `#A7C5D6` |
| Text on primary action | `#FFFFFF` | `#152D3B` |
| Selected / subtle accent surface | `#DDE8ED` | `#30434E` |
| Success ink | `#466A50` | `#A1C6A9` |
| Warning ink | `#825523` | `#DCB27C` |
| Error ink | `#A13D38` | `#E8AAA4` |

Use semantic names in implementation and map them into native color roles. The success, warning, and error colors above are text/icon colors on neutral surfaces, not untested button fills. Brand accent is separate from connection success. Pair state color with text or a meaningful symbol.

- Follow system appearance by default. Offer System / Light / Dark in settings. Test each scheme rather than simply inverting colors.
- Prefer system type: macOS native text styles; Android Material text roles and scalable `sp`. Native accessibility settings take precedence over fixed concept dimensions.
- Reference text sizes: Mac body 13–14 pt, secondary 12–13 pt, section title 14–16 pt, page title 24–28 pt. Android body 14–16 sp and supporting text 12–14 sp, mapped to Material roles.
- Use regular and medium weights for most content. Semibold can establish a heading. Avoid oversized title hierarchies, decorative display fonts in controls, or monospace as a technical costume.
- Use one native icon system per platform: SF Symbols on Mac and Material Symbols on Android. The browser concepts use Lucide only as a stand-in. Icons supplement essential labels.
- Spacing scale: 4, 8, 12, 16, 24, 32. Keep related content close and separate tasks with more space. Typical panel padding is 16–20, page padding 24–32 on Mac and 16–24 on Android.
- Reference radii: Mac small controls 6–8, content panels 10–12, floating companion 12; Android use Material shape roles, with roughly 16 for grouped panels. Do not impose one universal rounded shape on everything.
- Borders and tonal surfaces provide grouping. Soft shadows belong mainly to floating surfaces. No colored halos, gradient text, decorative glass, bouncing panels, or pulsing connectivity.
- Require at least 4.5:1 contrast for ordinary text and 3:1 for large text and meaningful control graphics. Preserve visible native focus indicators and screen-reader labels; color must never be the only state signal.

## Full Mac window

Use a familiar resizable window with a toolbar and sidebar. Sidebar destinations select pages; the selected device scopes the content. Keep these two concepts visually distinct.

The overview hierarchy is:

1. Selected device and readable connection/trust state.
2. A concise device information strip showing battery/charging and connection facts. Omit storage for now; leave the space open instead of adding replacement metrics.
3. A live-activity panel and a few pinned functional panels with useful content and direct controls.
4. A quiet route to the broader feature workspace and activity.

Overview, Features, Activity, and Settings form the navigation. Do not add a permanent destination for every capability. Features has space for new validated modules without reorganizing the whole application.

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

Start native evaluation with SwiftUI `MenuBarExtra` using `.menuBarExtraStyle(.window)` ([Apple presentation guidance](https://developer.apple.com/documentation/swiftui/menubarextrastyle)). Check focus, outside-click dismissal, Escape, keyboard access, and opening the full app on supported macOS versions. If a reproducible wrapper issue prevents the required behavior, evaluate an AppKit `NSPopover` or, when justified, an `NSPanel`. These are conditional alternatives, not a selected implementation or a guarantee of correct behavior; verify the same interaction contract with either approach.

## Android

Use a native top app bar, a visible device context, and Material navigation. Home, Features, Activity, and Settings share the same concepts as Mac. Keep battery/charging and connection facts in the device summary; omit storage for now.

Detailed panels stack on compact phones. Use a compact grid only for short actions or genuinely short content; do not shrink text or controls to force a desktop layout into two columns. Larger windows can use navigation rails and more columns when they improve the task.

Use native pickers, sheets, switches, and dialogs. Honor system Back, predictive Back where supported, window insets, text scaling, and reduced motion. Detailed or sustained work gets a screen; a brief contextual task may use a bottom sheet.

Plan for edge-to-edge rendering. Android 15 enforces it for apps targeting API 35 on Android 15 devices ([behavior changes](https://developer.android.com/about/versions/15/behavior-changes-15)). In Compose, protect top-bar, bottom-navigation, and other interactive content using `WindowInsets.safeDrawing` or the corresponding Material component inset handling ([Compose cutout guidance](https://developer.android.com/develop/ui/compose/system/cutouts)). Apply and consume insets once rather than doubling Scaffold and child padding. Test cutouts, gesture navigation, three-button navigation, and the on-screen keyboard; backgrounds may extend behind system bars while controls remain safe.

Every interactive target is at least 48 × 48 dp ([Android accessibility guidance](https://developer.android.com/guide/topics/ui/accessibility/views/apps-views)). Leave enough separation between controls. The drawn icon can remain smaller than its hit region. The static aniCe palette is the starting identity; optional Android Dynamic Color is a later explicit design choice, not an automatic replacement of this baseline.

## Live activities

One home panel hosts current sessions, active operations, and brief recent results. Now Playing is one possible activity rather than a permanent definition of the panel. This pattern is shared by Mac, Android, and the compact menu-bar companion.

- Show one activity at a time with its own useful content and controls. Provide labeled page indicators and previous/next controls. Disable activity swiping for the entire active card whenever it contains an interactive horizontal slider, including Now Playing's seek and volume controls. Use arrows or indicators on that card instead. On other cards, support horizontal swipe only when it does not conflict with scrolling or system navigation.
- Indicators represent the activities actually present. Do not reserve three slots or show an empty activity just to fill a carousel. Hide pagination for a single item.
- Never auto-rotate. Preserve the selected activity during interaction. New events may update the queue without moving a control under the user’s pointer or finger.
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
