# Product UX Improvements

Goal: make first setup and everyday device use obvious on Mac and Android, with fewer detours and plain-language status.

## Guardrails

- Keep BLE as the owner of automatic reconnect. Continue using connection and device events; do not add a periodic polling loop.
- Keep automatic LAN coordinated through authenticated BLE, with no independent LAN retry loop.
- A timed pause gates the existing connection owners until its saved deadline; expiry resumes their existing event-driven policy.
- Keep the Android background LAN timeout default at **Never** and preserve saved user choices.
- Apply automatic file receipt to new pairings only. Preserve existing peers’ saved choices.
- Keep Mac floating-keyboard behavior independent from full-screen trackpad controls.
- Store list order as local presentation state; it does not affect feature support or connection behavior.

## Phases

| Phase | Scope | Status | Commit subject |
| :--- | :--- | :--- | :--- |
| 1 | First launch: direct users to add a device and hide actions that cannot work yet. | Complete | `feat(onboarding): guide first device setup` |
| 2 | Pairing: make QR and six-digit code choices visible and explain the next step. | Complete | `feat(pairing): clarify QR and code setup` |
| 3 | Navigation: open selected peers in Devices, collapse details, and remove duplicate back links. | Complete | `fix(navigation): open selected peers in Devices` |
| 4 | Connection checks: show sent and received results for Bluetooth and LAN. | Complete | `fix(connection): show transport check feedback` |
| 5 | Transfer defaults: enable automatic receipt on new pairings while preserving existing choices. | Complete | `feat(transfer): enable auto receive for new pairings` |
| 6 | Mac full-screen trackpad: add keyboard input without changing the floating keyboard. | Complete | `feat(macos): add keyboard input to full-screen trackpad` |
| 7 | Connection pause: add 1, 3 and 6 hour, custom, and manual-resume choices with a saved deadline. | Complete | `feat(connection): add timed automatic reconnect pause` |
| 8 | Device setup: shorten Bluetooth linking and show trust controls only when there are devices to manage. | Complete | `fix(devices): streamline first connection setup` |
| 9 | Settings: tighten Mac spacing, use clear top-level navigation, and make the main connection defaults easy to find. | Complete | `feat(settings): simplify connection preferences` |
| 10 | Mac quick access: add a global shortcut that toggles the existing floating keyboard. | Complete | `feat(macos): add floating keyboard shortcut` |
| 11 | Lists: reorder Features and Favourites on both platforms; offer platform-native row actions. | Complete | `feat(navigation): reorder feature and favourite lists` |
| 12 | Feedback: remove the unpaired companion's stray action, explain offer review, confirm receive folders and reveal identity recovery in view. | Complete | `fix(ux): clarify first-run and file-transfer feedback` |

The Favourites empty state explains how to choose favourites. Phase 12 keeps it, hides the Mac companion's idle send row until a phone is trusted, names the receive folder before approval and after success, and scrolls the phone identity sheet to its reset control when Advanced opens.

## Review notes

- Connection checks already use the existing authenticated data path. A tap sends one check; the receiving side confirms it in its count. The UI update did not change the protocol.
- The current reconnect policy uses bounded backoff and native events. A timed pause should suspend that policy, not replace it with polling.
- Saved feature ordering is presentation-only; it does not alter support, permission, trust or connection behavior.
- Receive-folder names resolve through Android document providers off the UI thread.
- Phase commit subjects use Conventional Commit type/scope and say what changed; use the listed subject, expanding the affected surface when a phase grows.
