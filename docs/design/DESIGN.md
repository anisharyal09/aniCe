# aniCe design guide

Version 0.3. This guide defines visual direction, interaction behavior, standard colors, layout standards, and presentation rules for aniCe across macOS and Android. Technical protocols and wire contracts are defined in [protocol/](../../protocol/README.md); individual feature specifications are located in [docs/features/](../features/).

## Design principles

- **Clarity over ornament**: Warm neutrals with charcoal-green action ink. No blue glows, decorative gradients, artificial glassmorphism, or skeuomorphic shadows. Mac navigation and floating surfaces use optional native Liquid Glass on macOS 26+, semantic material on older systems and solid surfaces when disabled or Reduce Transparency is active. Text-heavy content panels remain solid or lightly tinted.
- **Native behavior**: Use platform-native controls, typography, and navigation patterns (macOS AppKit/SwiftUI with SF Symbols; Android Material 3/Compose with Material Symbols).
- **State truth**: Truthfully distinguish between trusted, connecting, secured, offline, permission-gated, and unsupported states. Never fake live state or display an invented zero.
- **Direct feedback**: Interactive controls respond with visible hover, pressed and focus feedback. Mac uses a restrained but noticeable semantic state layer (10% hover, 18% pressed) with a 140 ms hover transition, disabled under Reduce Motion. Filled selections use contrasting ink for feedback, including the light selected face in Dark and dark selected face in Light; inactive controls use accent ink. Android retains Material ripple/state layers for touch, keyboard focus and mouse/stylus hover where supported. No glow, scale bounce or hover-only actions.

## Brand mark

Use the transparent path-only ringless silver interlocking ribbon ([final SVG](../../assets/logo/anice-mark-final.svg)) on app brand surfaces.
- **macOS**: The packaged app/Finder icon reuses the same inset near-black artwork as the dark Dock icon, including in downloaded ZIPs. The running Dock follows system appearance: warm-light tile in Light mode, near-black tile with subtle inner glow and fine rim highlights in Dark mode. The menu-bar template uses a 21.5 pt template icon with shaded alpha.
- **Android**: The adaptive launcher reuses the near-black Dock background and edge highlights as an opaque tile, without Mac padding; Android retains its own mask and foreground sizing. Explicit system Light mode uses the warm-light tile. Launcher appearance follows the device theme, independently of aniCe's in-app Appearance setting.

## Visual system

Color communicates action and status, not decorative categorization. Always pair status colors with descriptive text or meaningful symbols.

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

- **Contrast**: Minimum 4.5:1 contrast for standard text; 3:1 for large text and meaningful control graphics.
- **Theme support**: Follow system appearance by default. Offer explicit System / Light / Dark modes in Settings.
- **Mac Native Glass**: General → Appearance offers a default-on master toggle and Standard (default) / Vibrant styles. Off restores solid surfaces. Reduce Transparency disables the toggle and displays **Locked to Normal by macOS System Settings** without overwriting the saved choice. Navigation uses native window materials rather than tinted floating-card glass. Standard adds a restrained semantic backing; Vibrant reduces that backing and uses thinner toolbar material, revealing more of the desktop without a colored wash. Floating surfaces retain native glass with semantic tint. System menu-bar and notification appearance remain OS-owned.

## Typography and text scaling

- **Typefaces**: macOS native system font (San Francisco); Android Roboto / system font via Material 3 typography roles.
- **Reference scale**:
  - macOS: Title 20 pt, Section title 14–16 pt, Body 13–14 pt, Secondary/Caption 12–13 pt.
  - Android: Page title 20 sp, Section title 14 sp, Body 13–14 sp, Secondary/Metadata 12 sp.
- **Dynamic text scaling**: Both platforms support 80%–120% dynamic text scaling (macOS Appearance settings slider; Android preferences). Layouts must reflow, wrap, and preserve touch targets across the entire scaling range.
- **Weights**: Regular and Medium for body content; Semibold for titles and section headings. Avoid decorative or oversized fonts.

## Layout and metrics

- **Spacing scale**: 4, 8, 12, 16, 24, 32 pt/dp.
- **Corner radii**:
  - Controls (buttons, inputs, toggles): 6–8 pt/dp.
  - Content containers and cards: 8–12 pt/dp.
  - Floating panels and sheets: 12–14 pt/dp.
- **Buttons**:
  - Wrapped, comfortably sized buttons with visible hover, active, and focus states.
  - Filled action ink is reserved for primary actions; secondary actions use subtle borders or neutral backgrounds.
  - Reuse Home's compact rectangular controls; Android keeps a 48 dp interaction area around the smaller face rather than stretching its border.

## Navigation and information architecture

Shared information architecture mapped into platform-native navigation:

| Destination | Purpose |
| --- | --- |
| Overview / Home | Active device context, current playback, file transfer progress, quick actions |
| Devices | Connection management, pairing, transport toggles (Bluetooth, LAN), device identity |
| Features | Feature launcher and per-feature settings |
| Favourites | Pinned quick-access features (defaults: Android = Control Mac, Desk Deck, Clipboard; macOS = Clipboard, Control Android, Messages) |
| Settings | App-wide preferences (Appearance, Text Scale, Permissions, LAN timeout) |
| About | Version, license, source, developer links, and support |

### macOS layout
- Sidebar pins are independent of Favourites and menu-bar pins, with Pin/Unpin in feature context menus. Pinned navigation scrolls vertically while Settings/About remain available. Overview and companion shortcut faces wrap in saved order. Companion uses native behind-window vibrancy and a separate quiet Support aniCe heart beside Open aniCe.
- **Main window**: Resizable window with traffic lights and Back/Forward history navigation on the left of the split header; aniCe branding in the window titlebar. Sidebar holds navigation destinations; workspace content is centered with a maximum of two columns.
- **Initial size and sidebar**: A new main window defaults to 960 × 640 pt; native resizing and restored window sizes remain in control. The sidebar uses a 27 pt brand mark and fits the wordmark and full destination labels at the current text size, with 12 pt of additional width. It remains resizable.
- **Menu-bar companion**: Compact popover (max 520 pt height) showing active device state, Now Playing, file transfers, quick actions, and pinned favorite shortcuts.
- Companion overflow contains Manage devices, Settings and Quit; the visible Paste tray action and global shortcut provide tray access without a duplicate overflow entry.
- **Quick Paste Tray**: Non-activating floating panel toggled via `⌥⌘V` with real-time clip filtering and smart previews.

### Android layout
- Home quick-access shortcuts wrap into rows, preserving labels and 48 dp targets without horizontal scrolling.
- Native top app bar with aniCe brand mark and About action.
- Five bottom destinations: Home, Devices, Features, Favourites, Settings.
- Native system Back and RTL support throughout.
- About retains an app-bar Back action. Full-screen input controls respect safe drawing and keyboard insets so Done, Stop and the editor remain reachable.
- Desk Deck retains standard app shell with app bar and navigation tabs.

## State truth

Connection, trust, support, permission, and enabled states are separate facts. Never display speculative or simulated data.

| Situation | Required presentation |
| --- | --- |
| Offline | State clearly as offline; label cached information as last known with timestamp. |
| Unknown data | Show unavailable or unknown, never an invented zero (e.g. battery or storage). |
| Permission needed | Inline explanation of why permission is required, with a direct button to system settings. |
| Unsupported capability | State unavailability clearly; do not offer non-functional controls. |
| Disabled feature | Explain state and provide an explicit toggle to enable. |
| Loading / Connecting | Stable layout with bounded placeholder; pending state on initiated controls. |
| LAN verification after a peer interruption | Show Checking LAN and withdraw the confirmed Wi-Fi indicator while checking; a still-secured Bluetooth link remains independent. |
| Interrupted operation | Explain the result and recovery path without unprompted blind retries. |

## Feature presentation standards

### Home and Overview
- Single device row showing connected device name, readiness status, and battery percentage when authenticated.
- Session control: Wrapped Pause button with grouped duration choices (1 hour, 3 hours, 6 hours, Until I resume, Custom…). When locally paused, show a play icon and a direct Resume action without a dropdown. The Auto connect switch reflects currently armed work, not merely a saved preference.
- Quick actions: Compact Send Files and Send Clipboard buttons.
- Home transfer panels use one inline title/chevron and omit feature settings or duplicate navigation rows.
- Keep the Home File transfer heading at the same normal section size across idle, active and result states. Mac picker confirmations center on the initiating display after native alert layout.
- Active work (transfers, current playback) displays prominently above secondary recent activity.

### Devices and pairing
- Flat peer list with readiness indicators and individual Bluetooth and Local Network connection controls.
- Pairing requires mutual approval on both devices via nearby six-digit comparison, QR code or entered 6-digit PIN.
- Device identity sheet displays name, fingerprint, and confirmed reset action.
- Private nicknames are separate from device-owned names. Default Use nickname to off; show the real device name in security details. Device-name edits sync live over existing authenticated channels and on reconnect while offline. Nicknames stay local, persist across restarts and take precedence only when enabled. Home, Devices, companion, feature peer pickers and file/clipboard destination labels use the same resolver. Immutable historic activity retains its event-time label; security and pairing identity remain separate from presentation.
- Nearby discovery uses generic anonymous candidates, never a claimed real device name. On first unpaired foreground launch, Android requests native Nearby Devices access once after Home is drawn. Granted access starts discovery without a Find nearby tap. Denial leaves a clear Allow nearby devices/Open app settings action within the Home connection entry, not another dialog on every launch. Find nearby remains explicit retry. One qualified candidate automatically opens the bounded comparison sheet after a short ambiguity check; multiple candidates retain a native selection sheet with Compare code, Dismiss and Manual pair. Selection freezes one candidate and stops scanning. Searching shows progress immediately. Preparing/comparison is observable UI state; Add device renders the same code and controls rather than hiding a global prompt. Surface removal alone must never approve or reject pairing. Dismissal and verification failure never silently retry an exchange. Pre-auth transport failures may retry twice with a ten-second cooldown; discovery starts with a bounded low-latency foreground burst. Trusted reconnects may try three times on foreground return without requesting companion setup repeatedly. Compare all six digits, including leading zeros, with Confirm on both devices and accessible Dismiss. No device names are disclosed until both comparison confirmations.
- With known-empty trust, Mac nearby availability starts while its process is awake/unlocked, retaining explicit Pause/Find nearby. Manual pair opens the existing QR/PIN flow. An incoming comparison uses a centered content card in the active app; otherwise use an AppKit floating panel near the top-center of the pointer's display, respecting visible-frame bounds. Showing the panel must not steal typing focus. Clicking its heading/code opens aniCe without approval; Confirm approves the same attempt and opens aniCe. Dismiss rejects without opening. Never regenerate or silently retarget the code during a surface handoff. Floating-card Confirm opens the regular Devices window, not a second pairing sheet with competing Cancel actions. Enter confirms only the displayed attempt; Escape/Dismiss reject. Mac stops generic nearby advertising while the pairing slot is occupied and while admission is cooling down; availability resumes automatically at the existing bounded admission deadline.
- Comparison confirmation is not Connected. Verify identity openings/proofs, store trust through the shared receipt flow, then establish fresh authenticated readiness. Default-on background auto-connect is visible as Reconnect automatically in Android's comparison sheet. Every pairing method and Devices Auto connect uses the same single-Mac native approval after a secured connection; no extra connection-settings page or broad device-management chooser is shown. Cancellation leaves trust intact. Lock, background loss, cancellation and expiry cannot approve an old attempt. Post-pair Android setup stays inline on Home with one retained owner and launches only Android's native approval, not a second aniCe activity/popup. Keep the note to **Reconnect when nearby, even in the background.** and state that allowing this phone and Mac connection does not grant feature permissions. Android owns the native dialog wording, which aniCe must not spoof or bypass. Its native device-scanning screen may precede approval. Keep the app's setup row stable, without a duplicate animated progress indicator while that native UI owns the request; do not deliberately insert an extra preparation frame. Feature permissions remain separate; rotation must not repeat approval, and cancellation keeps trust.
- Mac nearby setup retains explicit Bluetooth-off recovery even after the attempted discovery stops: name this Mac, direct to Bluetooth settings and require Find nearby retry. Do not show generic available/setup copy for a known failed radio state.
- Long-press a Devices name to open its editor directly; Mac also offers a native right-click Edit name action. This device edits the shared device-owned name; a paired device edits a private nickname. Normal taps/clicks retain details, and explicit edit controls in details remain available without gestures.

### Desk Deck and Control Android
- **Mac Desk Deck (Android)**: Real-time Mac telemetry display. Stale readings show their last-received timestamp, with compact header text wrapping above its trailing actions; very narrow large-text layouts use one meter column. Mac choices wrap as labeled native chips. Find Mac sits below the selected peer's status and uses the independent Find Device capability, never telemetry freshness; pending/results and Mac-local permission recovery stay in that tile. No separate Android Find Device launcher remains.
- **Control Android (macOS)**: Low-latency Classic HID mouse and keyboard input. Includes the Floating Key non-activating typing overlay in the menu-bar companion. See [Keyboard & Trackpad](../features/KEYBOARD_TRACKPAD.md).

### Now Playing
- Remote playback control scoped to the connected peer. See [Now Playing](../features/NOW_PLAYING.md).
- Centered track metadata (title, artist, album), fixed-dimension artwork placeholder to prevent layout shifts, transport controls (play/pause/skip), and volume slider.

### File transfer
- Compact entry progressing through file selection, recipient confirmation, transfer progress, and persistent result.
- Supports native macOS drag-and-drop and Android share sheets. See [File Transfer](../features/FILE_TRANSFER.md).
- Share action styling across send, receive, pause and result states; preserve primary/secondary roles and wrap long action groups instead of squeezing labels.
- Bluetooth fallback names its slower route and offers **Connect LAN for speed** in the existing transfer panel; no modal blocks an active batch. New local file actions request enabled automatic LAN but cannot undo a connection Pause.

### Messages (SMS relay)
- Scoped to connected phone. Threaded conversation list with chronological messages.
- Composer: Multi-line input at bottom; explicit SIM selector; byte counter near capacity limits.
- Mac SIM recovery stays in the affected conversation after Choose SIM: direct the user to the phone’s Permissions → SIM selection row and offer Refresh SIMs on the current connection. Keep default sending available; distinguish denied, failed and unanswered listings without inferring dual-SIM state. Successful empty/single-SIM listings omit setup reminders.
- Notifications: macOS notification previews with sound mute toggle under Settings.

### Clipboard
- Automatic clipboard sharing toggle (default off). Off means manual sharing via explicit Send Clipboard action.
- Focus-aware Android reading (respects Android 10+ privacy requirements).
- History: Local-only opt-in storage with configurable capacity (20/50/100 items). A labeled **History capacity** menu stays visible in Clipboard → History and Clipboard settings on both platforms, including compact settings and paused/off collection. Choosing a count does not enable collection; reducing it retains the newest eligible clips under the existing storage limits. Mac pins remain separate, with 100 clips maximum overall. See [Clipboard](../features/CLIPBOARD.md).
- Mac Share/History tabs use a roomier 32 pt face with 13 pt text and 12 pt horizontal insets; All/Pinned/Mac/Phone filters and glass-style choices keep compact 26 pt faces. Both stay content-sized, not stretched workspace-wide buttons. Open tray and preferences stay trailing and reflow beneath the tabs at narrow widths. Phone segments share the available row while keeping 48 dp interaction targets around their inset faces. No-match filters say **No matching clipboard items**, independently of collection state.

### Settings and About
- The dedicated Permissions category shows native access names, grant status and one short purpose per row. All contains missing-access actions only and omits the permission group when no access is missing. Feature settings retain recovery actions while blocked but never repeat granted-access descriptions. Permission rows share a name/status baseline, a 6 pt/dp purpose gap and visible space between permissions; no general settings button follows granted rows.
- Android lists SMS, Notification Access, SIM selection (Phone state access), Find Phone notifications, Answer phone calls, Call log, Contacts and Do Not Disturb access independently. SIM selection requests only READ_PHONE_STATE; call setup may request that shared grant with ANSWER_PHONE_CALLS. Find Phone notifications checks the existing incoming-alert channel as well as runtime/app access, without blocking outbound Find Mac. Mac identifies Event Posting, notifications and automatic pasteboard reading separately. Grant actions request missing permissions only and returning from native settings refreshes their state.
- Mac Shortcuts records global tray/Floating Key bindings only while its native recorder has focus. Defaults remain ⌥⌘V and ⌥⌘K. Command, Control, Option and Shift combinations, punctuation, navigation keys and function keys are supported. Plain typing, ordinary editing and enabled system hotkeys remain reserved. Registration failure keeps the previous binding. Labels follow the current keyboard layout.
- Settings defaults to All, an ordered scroll page with General, Permissions and Features headings; Mac also includes Shortcuts. Category controls filter without changing preferences, and phone controls wrap instead of scrolling horizontally. Android keeps tile/Share-sheet setup beside Clipboard rather than a keyboard-shortcut category. Mac uses one readable column, with Clipboard/Messages gears opening their exact category section.
- Mac Appearance aligns the Native Glass switch and style picker on the trailing edge; narrow layouts reflow without squeezing labels. Clipboard history pause sits beside collection status, with a trailing action and a separate line when needed.
- Mac selector rows share a leading label/helper column and a trailing intrinsic-size control. Keep helpers 6 pt below their label, not under the entire dropdown row. Shelf edge, History capacity and Window appearance align their visible control faces with the same trailing inset as switches, without unused width beside the native bezel. DND On/Off Shortcut menus use separate trailing rows; global shortcut recorder/Reset groups align trailing and wrap below their labels when needed. Long Shortcut names truncate in the control only and remain available in its menu/help.
- Persistent on/off preferences use a compact 38 × 22 pt/dp capsule with a fuller 18 pt/dp inset thumb. On blends accent ink over the subtle surface (78% light / 34% dark); Off uses the neutral control-track token. On thumbs use warm off-white in Light and light accent ink in Dark; Off thumbs use secondary ink. No glow or shadow. Labels lead and controls trail; helpers sit below the label. Consent/multi-selection retain checkboxes and permission grants retain status plus Allow actions.
- Mac label, helper and capsule share one clickable, keyboard-focusable control with native switch accessibility. Android's decorative capsule retains one switch-semantic, 48 dp labeled interaction area. Thumb transitions are brief and follow platform motion settings; control direction follows RTL. In light mode the on-state track uses muted sage ink with a warm off-white thumb; in dark mode it uses light accent ink over a muted track.
- Mac glass style and Clipboard tabs/history filters, plus phone Clipboard tabs/source filters, use one shared segmented control per platform. The selected segment carries semantic accent ink with contrasting text; inactive segments stay muted on a secondary surface. Each segment retains an accessible label, selected state and independent hover/pressed/focus feedback. Reselecting the active segment does not repeat its action. Phone peer choices remain wrapping native FilterChips for long names and multiple devices.
- Android Settings cards use 12 dp horizontal / 4 dp vertical insets with compact grouped rows; child sections must not add another outer inset.
- Keep setting labels and helper text in one column with the shared 6 dp gap (4 dp for compact rows); apply padding around the row, not between a separately padded control and its description.
- Keep helper copy brief; avoid redundant permission paragraphs or extra helper-text padding above permission/update actions.
- Android Connection labels its timeout **Idle LAN in background**, explains Home/lock and active-work exceptions, and identifies the work retaining LAN. The setting does not imply that Bluetooth or the app itself stops.
- Android Updates uses a compact labeled switch row for beta inclusion, followed by full-width status when present and one action row: **More options** at the leading edge with its chevron beside the label, **Check for updates** trailing. Keep both actions on one row when their measured text fits; reflow at narrow widths or large text without squeezing labels, retaining the trailing check action. Do not add a divider, a full-width bordered button or a separate empty disclosure row. Mac retains its native update actions. Enabling beta updates on either platform requires a native confirmation; cancellation leaves the setting unchanged, and disabling does not require another dialog.
- Both Updates sections keep **Check for updates automatically** inside a default-collapsed **More options** disclosure, using their shared preference switch. Automatic checks default on; show **Automatic checks are off.** when the disclosure is closed and the saved preference is off. Keep manual checking outside the disclosure and available independently.
- Android's automatic-check helper uses the compact **7:30 PM NPT** label; the schedule remains UTC+05:45.
- Android update review uses a native bottom sheet with a version badge and accessible Close action. Only the notes body scrolls; progress, byte counts and the current installation or cancellation action remain in the footer. More holds Skip version and View on GitHub. Close, Back and swipe dismiss review without cancelling active work. Mac keeps its notes in a bounded, bordered scroll area so the action row stays visible. Both platforms use the shared rectangular button shapes and render release-note headings, bold text, indented lists and horizontal rules in scalable native themed typography, hiding source metadata only in presentation and suppressing a leading version heading duplicated by the review title. Automatic checks retain the version in an open review; manual checks may refresh it.
- Mac Settings uses 13 pt body/section text and 12 pt supporting text at 100%, scaled through the existing text-size preference; other destinations keep their established scale.
- Dynamic text scaling slider (80%–120%) in macOS Appearance and Android settings.
- About section: Concise tagline `"Android + Mac, like never before."`, version metadata and license. Center the understated `[♡] Support aniCe :)` action horizontally, with a quiet **☆ Star aniCe on GitHub** text link centered directly beneath it. Keep the existing accent on `Ce` in both labels; the entire star label opens the repository without a separate URL, automatic starring, tracking or recurring prompts. Reflow text without truncation and retain native focus/pressed feedback and Android's 48 dp touch targets.
- About uses **Reach out** for the profile/contact row. Keep the label at the leading edge and the name/social actions trailing. When large text forces a second line, keep that group trailing rather than left-aligning it; do not orphan individual icons on another row.
- **Report an issue** opens a GitHub form containing only app/OS version information. Users review and submit it themselves; no automatic log, identity, message or file upload.
- Keep **Email** beside the **GitHub form** action in the About report row, with independent native links/touch targets; move the heading above the trailing action group when space is tight. Email opens the public maintainer address with only the fixed `[aniCe] Feedback & Support` subject, without a body, diagnostics or attachments. The user sends it from their email app.

## Design agent rules

Before any UI or frontend work, review this guide and the relevant feature documentation:

1. **Follow semantic tokens**: Use established semantic palette colors and typography styles; do not introduce custom one-off colors or fonts.
2. **Preserve native patterns**: Maintain native macOS and Android controls, interaction boundaries, and navigation hierarchy.
3. **Respect state truth**: Never invent mock data, hide failures, or assume connection state from discovery alone.
4. **Responsive & scalable**: Test UI changes across both Light and Dark themes, compact and expanded widths, and 80%–120% text scaling.
5. **Keep actions accessible**: Essential actions must be accessible without relying exclusively on hover states or gestures.
