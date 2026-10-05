# Current repository state

Current phase: **Phase 1A / Android App Foundation**.

The repository scaffold exists, including platform, shared-runtime, protocol, documentation, testing, tooling, automation, and agent-context boundaries.

Root, Android, macOS, and protocol changelogs exist with Unreleased sections. No releases have been published. Android uses development version `0.0.0-dev` (code `1`).

The project license is GNU GPL version 3 or later (`GPL-3.0-or-later`), with the full license text in root `LICENSE`.

The UI design direction is documented in `docs/design/DESIGN.md`. Android now has one native Compose starting screen and top app bar, following system appearance and safe insets. Device capabilities remain unimplemented.

`apps/android/` contains one `:app` module, a checked-in Gradle wrapper, and pinned dependencies. Compile/target SDK is stable API 36; API 29 minimum is provisional. Gradle uses Studio JDK 21; Java/Kotlin target JVM 17. `assembleDebug` and `lintDebug` pass. A user-provided emulator screenshot confirms the expected screen launches in dark appearance and portrait orientation.

Remaining verification: emulator API/image configuration, reproducible cold launch, background/resume, landscape, light appearance, maximum font scaling, and three-button navigation. The Android README contains build and run instructions; verification tracking stays in this operational context.

Not implemented or configured:

- macOS application project.
- Rust crate.
- Protocol schema files.
- Generated protocol models or protocol implementation.
- Pairing, authentication, cryptography, BLE, or LAN networking.
- Device runtime functionality beyond the Android starting screen.
- macOS and Rust dependencies or build toolchains.
- CI/CD.
