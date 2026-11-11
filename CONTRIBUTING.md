# Contributing to aniCe

Welcome to aniCe! 🎉 We're excited to have you contribute. Stable, mindfully and logically processed pull requests that carry tangible value are deeply appreciated—whether you are fixing a subtle edge case, improving documentation, polishing the UI, or proposing a new capability.

---

## Getting Started

### Local Setup & Verification

Before opening a pull request, we recommend running our local test suite to ensure everything builds and passes cleanly:

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
- **macOS:** Requires macOS with Xcode. Run `python3 scripts/verify-suite.py --only macos`.
- **Android:** Requires Android SDK and Java 21. Run `python3 scripts/verify-suite.py --only android`.

---

## Pull Request Guidelines

To help us review and merge your changes smoothly, here are a few best practices:

### 1. Mindful PRs & Meaningful, Complete Commits
- **Valuable, Well-Reasoned PRs:** We deeply appreciate pull requests that are stable, well-reasoned, and carry tangible value. Taking the time to think through edge cases, platform nuances, and stability ensures the codebase remains reliable for everyone.
- **Complete, Cohesive Commits:** Rather than pushing lots of fragmented micro-commits (e.g. tiny WIP fragments or minor churn), aim for complete, self-contained commits where each commit represents a logical, functioning increment.
- **Conventional Commits:** We encourage [Conventional Commits](https://www.conventionalcommits.org/) (e.g., `feat:`, `fix:`, `docs:`, `ci:`, `refactor:`). While not mandatory, clear commit messages make tracking releases and history much simpler!

### 2. Testing Your Changes
- **Automated Tests:** Make sure existing tests pass and add unit/integration tests for your changes where practical.
- **Manual Verification:** Since aniCe deals with cross-device interactions (BLE, LAN, pairing, and UI), please test your changes on a real device or emulator/simulator when relevant, and briefly describe what you verified in your PR description.

### 3. Visual Changes (UI/UX)
- If your PR introduces or modifies any user interface on macOS or Android, please include a quick before/after screenshot or screen recording in your PR. It provides immediate visual context for reviewers.

### 4. Documentation
- If you're introducing notable features, configuration changes, or architectural updates, please update the relevant documentation in `docs/` (or the component README) and add a short note under `## [Unreleased]` in `CHANGELOG.md`.

---

## Code Style & Conventions

- **Rust (`core/rust/`):** Format with `cargo fmt` and check with `cargo clippy`.
- **Swift (`apps/macos/`):** Follow Swift 6 modern concurrency patterns and target Apple Silicon (`arm64`).
- **Kotlin (`apps/android/`):** Follow modern Android architecture and Jetpack Compose conventions (minSdk 29).
- **Python (`scripts/`):** Target Python 3.11+ using standard library wherever possible.

---

## Security & Sensitive Areas

aniCe handles cryptographic pairing and encrypted peer-to-peer communication. Changes to security-sensitive components (cryptographic handshakes, key storage, CI workflows) receive thorough review.

If you believe you have found a security vulnerability, please refer to our [Security Policy](SECURITY.md) to report it privately.

---

## Need Help?

Not sure where to start, or hit a roadblock? Don't hesitate to open an issue or submit a draft PR. We're happy to answer questions, discuss design ideas, and help you get your PR across the finish line!
