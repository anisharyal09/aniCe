# Repository changelog

Repository-wide structure, documentation, and development conventions belong here. Android, macOS, and protocol changes have separate changelogs and may be versioned independently:

- [Android](apps/android/CHANGELOG.md)
- [macOS](apps/macos/CHANGELOG.md)
- [Protocol](protocol/CHANGELOG.md)

## Unreleased

### Added

- Minimal monorepo scaffold for Android, macOS, optional shared Rust logic, protocol contracts under `protocol/schemas/`, documentation, tests, tools, and scripts. Schema and serialization formats remain undecided.
- Root README and agent context describing project direction, current repository state, unresolved decisions, and navigation to design and change history.
- Design guide covering the Mac window, menu-bar companion, Android, semantic colors, live activities, clipboard preferences, and native implementation constraints.
- Separate component changelogs and generic ignore rules for generated output, local configuration, and private planning references.
- GNU GPL version 3 license text and an explicit GPL-3.0-or-later licensing declaration.

### Changed

- Update repository status and agent context for the Android foundation; its implementation is recorded in the Android changelog.

The Android starting screen and build toolchain now exist. macOS, protocol schemas, device capabilities, shared runtime, and CI remain deferred. No releases exist yet.
