# Contributing to aniCe

Keep changes focused, explain their user-visible effect, and run the checks relevant to the changed code.

## Getting Started

### Setup and checks

Set up the toolchain, then run the checks relevant to the change.

Use Python 3.11 or newer for the repository helper scripts.

```bash
# 1. Set up the Python virtual environment
python3 -m venv .venv
source .venv/bin/activate
pip install -r scripts/requirements.txt

# 2. Run fast integrity and contract checks
python3 scripts/verify-suite.py --only ci-integrity
python3 scripts/verify-suite.py --only contracts
python3 scripts/verify-suite.py --only rust

# 3. Check all available test lanes
python3 scripts/verify-suite.py --list-lanes
```

For platform-specific testing:

- **macOS:** Requires Apple Silicon (`arm64`), macOS 14 or newer, full Xcode and the [native Rust prerequisites](core/rust/pairing/README.md). Run `python3 scripts/verify-suite.py --only macos`.
- **Android:** Requires Android SDK and Java 21. Run `python3 scripts/verify-suite.py --only android`.

The `ci-integrity` lane also requires actionlint 1.7.12 on `PATH`; it is not installed by pip.

### What each lane verifies

| Lane | Evidence |
| --- | --- |
| `ci-integrity` | actionlint and workflow authorization/pinning tests |
| `contracts` | Structure/documentation links, every fixture generator in check-only mode, independent session crypto-oracle tests and Python harness tests |
| `rust` | `cargo fmt --check`, warning-free Clippy and all PAKE bridge tests with the lockfile |
| `android` | Fresh JVM test reports, Android lint and instrumentation-source compilation |
| `macos` | Fresh native bridge, Release build, arm64/code-signature checks and hosted tests including isolated Keychain tests |
| `connected` | Android instrumentation on one explicitly selected authorized target |
| `interchange` | Native Mac/Android identity, LAN and session harnesses on a prepared test installation |

The connected lane uses the isolated UI preview package on emulators. Companion-only regressions are SDK-gated to API 31+; synthetic comparison/setup presentation fixtures require the UI-preview emulator, not a physical installation. Native interchange and real-radio/player tests require their explicit harness or setup. Physical-device runs and interchange can install/replace the normal Debug package; use a dedicated test installation and pass `--serial`, not a phone whose app state must be preserved. Keyboard-specific manual diagnostics are described in the [IME probe](tools/ime-probe/README.md).

Reports live under `build/reports/verification/run-*/`. A zero exit alone is insufficient: missing/truncated results, duplicate test cases, failures and unreviewed skips are rejected. Count floors guard against suite disappearance; only passing native cases count toward them. Change a floor only after reviewing actual test removal, not to make a failing run green.

Run Android build/test lanes sequentially within one checkout: JVM, connected,
interchange and preview builds share Gradle outputs. Use a single
`--only android --only connected --serial DEVICE_SERIAL` invocation for ordered
host and runtime acceptance.

Keep regression tests that exercise distinct failure boundaries. Remove superseded probes or unused fixtures only after checking their callers, native resource membership and documented purpose. Update dependency pins for a reviewed fix or compatibility need, then verify fixture bytes and native behavior; do not refresh versions merely because newer ones exist.

Physical BLE, minimum-OS behavior, real-player controls, permission persistence and signed update/rollback acceptance are separate from host-suite success. Document omissions rather than treating them as passed.

## Pull requests

- Describe the problem, resulting behavior and the checks performed.
- Add regression tests for changed logic and update the relevant guide or contract. UI changes should include before/after captures.
- Use cohesive commits with descriptive subjects; Conventional Commits are welcome.
- Record shared changes in the root changelog and platform/contract details in their component changelogs. Keep entries under Unreleased until publication, ordered Added, Changed, Fixed. Earlier versions marked as development milestones are not published releases.
- Do not include private signing credentials, local audit logs or maintainer checklists.

## Code Style & Conventions

- **Rust (`core/rust/`):** Format with `cargo fmt` and check with `cargo clippy`.
- **Swift (`apps/macos/`):** Follow Swift 6 modern concurrency patterns and target Apple Silicon (`arm64`).
- **Kotlin (`apps/android/`):** Follow modern Android architecture and Jetpack Compose conventions (minSdk 29).
- **Python (`scripts/`):** Target Python 3.11+ using standard library wherever possible.

## Security & Sensitive Areas

Changes to pairing, key storage, authenticated sessions, update installation or release workflows must preserve their validation and authorization boundaries.

If you believe you have found a security vulnerability, please refer to our [Security Policy](SECURITY.md) to report it privately.
