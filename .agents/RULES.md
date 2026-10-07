# Development constraints

- Define shared protocol contracts under `protocol/`; do not invent wire formats elsewhere.
- Do not introduce feature-specific pairing, security, or networking stacks. Features should use shared infrastructure when it exists.
- Keep platform-specific APIs within their respective platform implementations.
- Do not introduce Rust merely for code-sharing aesthetics; require concrete shared runtime needs.
- Once generation exists, do not manually modify generated protocol models. Update their source schemas instead.
- Inspect existing code and specifications before introducing abstractions.
- Keep scoped work focused; do not make unrelated architectural changes.
- Do not present unresolved ideas as settled architecture. Record open questions in `NOTES.md` and document decisions when resolved.
- Record repository-wide changes in the root `CHANGELOG.md` and component changes in the relevant Android, macOS, or protocol changelog. Keep unreleased work distinct from releases; do not invent versions or duplicate every entry across logs.
- aniCe uses `GPL-3.0-or-later`. Add the matching SPDX notice to new project-owned source files using the language's comment syntax. Before incorporating third-party code or assets, check license compatibility and preserve required upstream notices; do not relabel third-party material as aniCe-owned code.

## UI and design work

- For any UI or frontend task, you must read [docs/design/DESIGN.md](../docs/design/DESIGN.md) before writing code; it defines the current design direction and detailed agent rules.
- Reuse its semantic tokens, content-bearing panel patterns, and shared device/state vocabulary while honoring native Mac and Android behavior.
- Do not treat mockup features as implemented capabilities or as an approved feature inventory.
- Preserve the design direction during scoped work. Record justified, authorized changes in the human design guide rather than creating a competing agent design system.
- Reuse the live-activity panel for current and transient operations. Preserve the automatic clipboard-sharing toggle with manual sharing when off, and keep storage out of device summaries for now.
- Disable activity swiping on slider-bearing cards. Follow the guide's Android safe-inset and native Mac focus/dismissal verification requirements; AppKit alternatives remain conditional.