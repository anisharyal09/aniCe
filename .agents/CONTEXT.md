# Project context

aniCe is one planned local-first, modular ecosystem. Android and macOS come first, using Kotlin and Swift respectively. Platform applications belong under `apps/`; platform-specific APIs remain within their platform implementations.

The architectural direction is to maintain persistent trusted-device relationships and share communication infrastructure across features:

- **Control Pipe:** small structured messages, control operations, and metadata.
- **Data Pipe:** bulk transfers and continuous data streams.
- **BLE:** discovery, control, and bootstrap direction.
- **LAN:** high-bandwidth data direction.

These describe intended responsibilities, not implemented APIs or finalized transport, security, or topology choices.

Shared communication contracts belong under `protocol/`, with `schemas/` reserved for future definitions and `test-vectors/` for shared verification cases. The direction is schema-first; the schema language, serialization format, and generation approach remain undecided. There are currently no schemas or generated models.

`core/rust/` is reserved for genuinely useful shared runtime logic. Introduce Rust only when concrete requirements justify it.

Human-facing documentation belongs in `docs/`. Keep `.agents/` small and focused on operational context; it must not duplicate the human documentation tree. Unresolved implementation choices live in `NOTES.md`, and current repository reality lives in `STATE.md`.
