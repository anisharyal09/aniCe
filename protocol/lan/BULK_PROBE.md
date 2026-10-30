# Experimental bulk benchmark profile

This profile is selectable only by the isolated native LAN benchmark configuration. It is separate from the production [LAN transfer profile](TRANSFER_PROFILE.md), which negotiates 256-KiB DATA records. This experimental 4-MiB profile has no production feature integration.

Discovery uses the isolated `_anicebulk._tcp` service with TXT `v=1`; standard discovery ignores it. Fresh TCP and EDHOC authenticate the pinned disposable peer. Both endpoints explicitly select `bulk-probe`; incoming bytes cannot select or downgrade the local profile. EDHOC messages and CBOR limits remain unchanged.

## Framing and records

TCP framing is `version:u8=2 || envelopeLength:u32be || envelope`, bounded to 2–4,194,335 bytes. Handshake envelopes (kinds 1–5) retain the 4,096-byte bound; encrypted-record envelope kind 6 may use the larger bound. One partial frame follows the [LAN assembly deadline policy](README.md); standalone framing probes retain the ten-second absolute limit unless secured readiness is explicitly established.

AES-256-GCM records retain the existing 14-byte header layout: `version:u8=2 || kind:u8 || sequence:u64be || plaintextLength:u32be`. DATA plaintext is bounded to 4,194,304 bytes; readiness/close plaintext remains empty. The 16-byte tag, strict directional sequence, nonce XOR construction, AAD `header || sessionID || direction:u8`, one-hour lifetime and `2^20` directional record limit remain.

Exporter context is deterministic CBOR `["aniCe bulk probe", 1, maximumPlaintext:int=4194304, initiatorBinding:bstr, responderBinding:bstr, direction:int, purpose:tstr]`. Key/IV/session-ID exports retain their existing lengths and purpose names, with separate domain binding from standard sessions. Every send/receive retains existing native identity/trust validation and post-suspension generation checks. No protection cache or skipped validation is introduced.

## Bounded benchmark flow

The benchmark body is at most 4,194,299 bytes, leaving five bytes for its existing kind/offset header. A four- or eight-block logical window uses cumulative ACKs every half-window and at EOF. The transport retains at most four envelopes and 16,777,340 bytes; refusal remains before sealing. Submitted records are never replayed. The standard transport remains eight envelopes/32 KiB and standard DATA remains 4,000 bytes.

This probe measures whether native-validation overhead can be amortized without changing the control channel. Throughput success alone does not establish media latency, memory/battery, supported-OS or production bulk-channel acceptance.
