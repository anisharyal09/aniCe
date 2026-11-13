# Contributing to aniCe

Keep changes focused, explain their user-visible effect, and run the checks relevant to the changed code.

## Getting Started

### Local Setup & Verification

Before opening a pull request, we recommend running our local test suite to ensure everything builds and passes cleanly:

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

## Pull requests

- Describe the problem, resulting behavior and validation. Note physical-device checks that remain pending.
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
