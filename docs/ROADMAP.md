# Roadmap

Preparing the first public beta, with development version **0.9.0-beta.1 · build 90021**. Published versions belong in [GitHub Releases](https://github.com/anisharyal09/aniCe/releases); development history is in the [changelog](../CHANGELOG.md).

## Before the first beta

- Verify the signed baseline and update pair on physical Android and Apple Silicon Mac devices, including failed-download/install recovery and preservation of identity, trust and permissions.
- Exercise QR/code pairing, connection pause expiry/resume, bidirectional Bluetooth/LAN checks and manual/automatic file receiving.
- Check Mac Dock/Stage Manager reopening, Android Settings navigation and identity-sheet expansion, large text and native picker return. Automated builds and offscreen renders do not establish these interactions.
- Measure file transfer with simultaneous playback/control traffic, connected-idle CPU and background continuity. See [performance evidence and open work](PERFORMANCE.md).
- Review signing, Mac unsandboxed access, update authorization and published security claims. Hosted static analysis does not replace this review.

## Later work

- Android reboot recovery and a general Bluetooth foreground-service fallback.
- Coordinated LAN security-session renewal during long transfers.
- Signed Mac data-protection Keychain/Secure Enclave acceptance and an explicit migration plan from development storage.
- Broader minimum-OS, permission-denial, process-death, sleep/wake and supported-player acceptance.
- Optional Add to Home and manual trusted-device ordering; these are not implemented promises.

Feature behavior and limitations live in the [feature guides](../README.md#features). Ownership belongs in [architecture](../ARCHITECTURE.md); compatibility belongs in [protocol contracts](../protocol/README.md).
