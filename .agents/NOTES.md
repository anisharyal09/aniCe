# Unresolved matters

Notes are not architectural decisions. Resolve these through concrete requirements and record the resulting decisions in appropriate human documentation.

- Final minimum Android and macOS versions. Android API 29 / Android 10 and macOS 14 are provisional foundation baselines, not product freezes.
- Exact cryptographic suite.
- BLE topology.
- Exact LAN transport.
- Protocol schema language, serialization format (such as JSON, CBOR, or Protobuf), and model-generation approach.
- The point at which shared runtime needs justify Rust.
- Platform feasibility and permissions for automatic clipboard sharing and call-related integrations.
