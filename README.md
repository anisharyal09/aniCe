# aniCe

**Your phone and Mac, working together.**

aniCe is a planned local-first ecosystem for Android and macOS. The aim is a set of useful device-to-device capabilities built around lasting trust, shared communication, and interfaces that feel at home on each platform.

[Design direction](docs/design/DESIGN.md) · [Changelog](CHANGELOG.md) · [Agent guide](AGENTS.md)

## The direction

- **Local first.** Start with trusted devices communicating locally.
- **Native on both sides.** Kotlin for Android, Swift for macOS, with one recognizable design vocabulary.
- **Shared foundations.** Features build on common trust and communication infrastructure.
- **Room to grow.** Modular capabilities and independent platform versions. Rust enters only when a concrete shared runtime need justifies it.

## Where things stand

**Phase 0.5 — Repository Initialization.**

This repository contains the directory scaffold, project context, changelogs, and design guide. No application projects, protocol schemas, build toolchains, dependencies, or runtime functionality have been implemented. There is no app to install or run yet.

The design guide covers the full Mac window, menu-bar companion, and Android adaptation. Its sample panels illustrate interface direction; they do not promise implemented features or confirmed platform support.

## Repository layout

| Directory | Responsibility |
| --- | --- |
| `apps/` | Native Android and macOS applications. |
| `core/` | Shared runtime logic; `rust/` reserves space until needed. |
| `protocol/` | Communication contracts: `schemas/` for definitions, `test-vectors/` for verification cases. Formats remain undecided. |
| `docs/` | Human-facing product and architecture documentation. |
| `.agents/` | Concise operational context for coding agents. |
| `tests/` | Cross-platform and system verification. |
| `tools/` | Repository-local developer utilities. |
| `scripts/` | Automation glue. |

Empty directories contain `.gitkeep` placeholders so Git can preserve the layout. Remove a placeholder when its directory gains actual tracked content.

## Following changes

The [root changelog](CHANGELOG.md) tracks repository-wide work. Application and protocol changes have their own logs: [Android](apps/android/CHANGELOG.md), [macOS](apps/macos/CHANGELOG.md), and [protocol](protocol/CHANGELOG.md). All are currently unreleased.

## License

aniCe is licensed under the [GNU General Public License](LICENSE), version 3 or, at your option, any later version (**GPL-3.0-or-later**).
