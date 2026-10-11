# Architecture decisions

Decisions affecting the whole app or shared infrastructure live at this level, even when a feature motivates them. Feature-specific decisions live under `features/<feature>/`; keep ADR numbers stable when moving files. Create feature folders only for implemented work. Usage belongs in `docs/features/`, and wire contracts belong in `protocol/`.

## Shared architecture

- [0001 — Device identity](0001-provisional-device-identity.md)
- [0002 — BLE discovery](0002-provisional-ble-discovery.md)
- [0003 — Pairing and trust](0003-provisional-pairing-and-trust.md)
- [0004 — BLE attribute layout](0004-stable-ble-attribute-layout.md)
- [0005 — Secure sessions](0005-edhoc-secure-sessions.md)
- [0006 — Independent LAN sessions](0006-independent-lan-sessions.md)
- [0007 — Mac app process boundary and signing](0007-macos-unsandboxed-playback-prototype.md)
- [0008 — Application DATA feature boundaries](0008-application-data-feature-boundaries.md)

## Features

### Now Playing

- [0009 — Remote playback, notifications and volume](features/now-playing/0009-remote-playback-presentation.md)
- [Usage and limitations](../features/NOW_PLAYING.md)
