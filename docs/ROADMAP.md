# Roadmap

Current release: **v0.3.0, build 3**. Changes after that release are recorded under Unreleased in the [repository changelog](../CHANGELOG.md) and platform changelogs. Implementation status does not imply acceptance on every device or OS version.

| Area | Current implementation | Remaining work or limits |
| :--- | :--- | :--- |
| Identity and trust | Native P-256 identity, QR/OPAQUE pairing, mutual approval and persisted trust | Mac app identity uses the development Keychain backend; signed Secure Enclave storage needs runtime evidence. |
| BLE sessions | EDHOC, encrypted records, readiness, deadline-driven maintenance and fresh-session renewal | Android automatic ownership requires supported companion APIs; phone reboot recovery and a general BLE foreground-service fallback are absent. |
| LAN sessions | Independent manual LAN and BLE-coordinated automatic LAN; automatic preference defaults on | Automatic LAN requires secured BLE coordination. No independent LAN retry loop. |
| File transfer | Bidirectional batches, per-sender automatic receipt, saved destinations, progress and checkpoint recovery | Coordinated LAN security-session renewal remains deferred; source selection and unfinished initial hashing do not recover after restart. |
| Now Playing | Remote Mac playback, player selection, seek, artwork and volume controls | Platform/player support and background ownership limits apply. |
| Find Device | Peer alerts, Android ringing/Stop/expiry and Mac notifications | Remaining physical device-state matrix is recorded in the feature guide. |
| Clipboard | Manual text/link sharing, optional automatic sharing and local history | Android observation requires input focus; background receiving can overwrite a newer local clipboard. |
| Messages | Android SMS relay, Mac notifications, conversation/history/search and replies | RCS, MMS sending, attachments, contact resolution and mark-as-read are excluded. |
| Remote input | Mac-to-Android Bluetooth HID and Android-to-Mac authenticated input | OS pairing/permissions and deliberate input activation remain required. |
| UX and recovery | Guided pairing, device navigation, timed pauses, Settings categories, ordered Features/Favourites and Mac reopen recovery | Physical acceptance and optional follow-ups are listed in the [UX audit](UX_IMPROVEMENTS.md). |

## Sources of truth

- [Architecture](../ARCHITECTURE.md): ownership, identity and connection boundaries.
- [Protocol index](../protocol/README.md): wire contracts and compatibility.
- [Background connections](BACKGROUND_CONNECTIONS.md) and [LAN policy](LAN_CONNECTIONS.md): lifecycle and automatic connection rules.
- [Performance](PERFORMANCE.md): measurements and remaining performance work.
- [Design guide](design/DESIGN.md): product behavior and native interaction requirements.
- Feature guides: [file transfer](features/FILE_TRANSFER.md), [Now Playing](features/NOW_PLAYING.md), [Find Device](features/FIND_DEVICE.md), [Clipboard](features/CLIPBOARD.md), [Messages](features/SMS.md), [Control Android](features/KEYBOARD_TRACKPAD.md), and [Control Mac](features/PHONE_TO_MAC.md).

See the [UX audit](UX_IMPROVEMENTS.md) for the original request checklist and verification limits. Future commits require explicit authorization under the repository instructions; proposed commit subjects are not implementation evidence.
