# aniCe design guide

Version 0.3. This guide defines visual direction, interaction behavior, standard colors, layout standards, and presentation rules for aniCe across macOS and Android. Technical protocols and wire contracts are defined in [protocol/](../../protocol/README.md); individual feature specifications are located in [docs/features/](../features/).

## Design principles

- **Clarity over ornament**: Warm neutrals with charcoal-green action ink. No blue glows, decorative gradients, artificial glassmorphism, or skeuomorphic shadows.
- **Native behavior**: Use platform-native controls, typography, and navigation patterns (macOS AppKit/SwiftUI with SF Symbols; Android Material 3/Compose with Material Symbols).
- **State truth**: Truthfully distinguish between trusted, connecting, secured, offline, permission-gated, and unsupported states. Never fake live state or display an invented zero.
- **Direct feedback**: Interactive controls respond immediately with visible hover, pressed, and focus feedback. Transitions are brief (120–220 ms) and respect system reduced-motion settings.

## Brand mark

Use the transparent path-only ringless silver interlocking ribbon ([final SVG](../../assets/logo/anice-mark-final.svg)) on app brand surfaces.
- **macOS**: Full rounded warm-light tile in Light appearance; inset dark graphite tile with subtle inner glow and fine rim highlights in Dark appearance. The menu-bar template uses a 21.5 pt template icon with shaded alpha.
- **Android**: Adaptive icon with foreground ribbon and toned background with dark graphite glow in Dark appearance.

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
  - Touch targets retain a minimum 48 dp bound on Android.

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
- **Main window**: Resizable window with traffic lights and Back/Forward history navigation on the left of the split header; aniCe branding in the window titlebar. Sidebar holds navigation destinations; workspace content is centered with a maximum of two columns.
- **Menu-bar companion**: Compact popover (max 520 pt height) showing active device state, Now Playing, file transfers, quick actions, and pinned favorite shortcuts.
- **Quick Paste Tray**: Non-activating floating panel toggled via `⌥⌘V` with real-time clip filtering and smart previews.

### Android layout
- Native top app bar with aniCe brand mark and About action.
- Five bottom destinations: Home, Devices, Features, Favourites, Settings.
- Native system Back and RTL support throughout.
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
| Interrupted operation | Explain the result and recovery path without unprompted blind retries. |

## Feature presentation standards

### Home and Overview
- Single device row showing connected device name, readiness status, and battery percentage when authenticated.
- Session control: Wrapped Pause button with duration menu (15m, 1h, 8h, Until tomorrow) and Resume now when paused.
- Quick actions: Compact Send Files and Send Clipboard buttons.
- Active work (transfers, current playback) displays prominently above secondary recent activity.

### Devices and pairing
- Flat peer list with readiness indicators and individual Bluetooth and Local Network connection controls.
- Pairing requires mutual approval on both devices via QR code or 6-digit PIN.
- Device identity sheet displays name, fingerprint, and confirmed reset action.

### Desk Deck and Control Android
- **Mac Desk Deck (Android)**: Real-time Mac telemetry display. Stale readings show their last-received timestamp.
- **Control Android (macOS)**: Low-latency Classic HID mouse and keyboard input. Includes the Floating Key non-activating typing overlay in the menu-bar companion. See [Keyboard & Trackpad](../features/KEYBOARD_TRACKPAD.md).

### Now Playing
- Remote playback control scoped to the connected peer. See [Now Playing](../features/NOW_PLAYING.md).
- Centered track metadata (title, artist, album), fixed-dimension artwork placeholder to prevent layout shifts, transport controls (play/pause/skip), and volume slider.

### File transfer
- Compact entry progressing through file selection, recipient confirmation, transfer progress, and persistent result.
- Supports native macOS drag-and-drop and Android share sheets. See [File Transfer](../features/FILE_TRANSFER.md).

### Messages (SMS relay)
- Scoped to connected phone. Threaded conversation list with chronological messages.
- Composer: Multi-line input at bottom; explicit SIM selector; byte counter near capacity limits.
- Notifications: macOS notification previews with sound mute toggle under Settings.

### Clipboard
- Automatic clipboard sharing toggle (default off). Off means manual sharing via explicit Send Clipboard action.
- Focus-aware Android reading (respects Android 10+ privacy requirements).
- History: Local-only opt-in storage with configurable capacity (20/50/100 items). See [Clipboard](../features/CLIPBOARD.md).

### Settings and About
- Grouped preferences using native controls (toggles, sliders, pickers).
- Android Updates uses a compact labeled checkbox row for beta inclusion, with update status and the text **Check for updates** action sharing one trailing row. At narrow widths or large text, put status above the trailing action rather than squeezing it into a thin column. Do not add a divider or a full-width bordered button between them. Mac retains its native update actions. Enabling beta updates on either platform requires a native confirmation; cancellation leaves the setting unchanged, and disabling does not require another dialog.
- Mac Settings uses 13 pt body/section text and 12 pt supporting text at 100%, scaled through the existing text-size preference; other destinations keep their established scale.
- Dynamic text scaling slider (80%–120%) in macOS Appearance and Android settings.
- About section: Concise tagline `"Android + Mac, like never before."`, version metadata, license, and understated `[♡] Support aniCe :)`.
- About uses **Reach out** for the profile/contact row. Keep the label at the leading edge and the name/social actions trailing. When large text forces a second line, keep that group trailing rather than left-aligning it; do not orphan individual icons on another row.
- **Report an issue** opens a GitHub form containing only app/OS version information. Users review and submit it themselves; no automatic log, identity, message or file upload.

## Design agent rules

Before any UI or frontend work, review this guide and the relevant feature documentation:

1. **Follow semantic tokens**: Use established semantic palette colors and typography styles; do not introduce custom one-off colors or fonts.
2. **Preserve native patterns**: Maintain native macOS and Android controls, interaction boundaries, and navigation hierarchy.
3. **Respect state truth**: Never invent mock data, hide failures, or assume connection state from discovery alone.
4. **Responsive & scalable**: Test UI changes across both Light and Dark themes, compact and expanded widths, and 80%–120% text scaling.
5. **Keep actions accessible**: Essential actions must be accessible without relying exclusively on hover states or gestures.
