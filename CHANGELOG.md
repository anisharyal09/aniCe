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

- Extend ignore rules for Kotlin and native Android build caches, Xcode result bundles, archives, and debug-symbol bundles.
- Update repository status and agent context for the Android and macOS foundations; implementation changes are recorded in their component changelogs.

Android uses development version `0.0.0-dev`; macOS uses numeric `0.0.0` to follow Apple's bundle-version conventions. Both identify unreleased foundations, not published releases.

Both native application projects now exist. macOS build and runtime verification remain pending local Xcode setup. Protocol schemas, device capabilities, shared runtime, and CI remain deferred.
