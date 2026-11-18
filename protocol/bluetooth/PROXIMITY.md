<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Nearby pairing discovery foundation

This is a staged implementation, not a supported SAS pairing protocol yet.
Mac remains the peripheral; Android remains the central. No bonding is requested.

## Anonymous availability

The advertisement remains the public aniCe service UUID and optional generic name.
Apple's peripheral advertising API does not provide arbitrary service/manufacturer
payloads. The existing 20-byte discovery characteristic retains its version,
flags and random nonce layout. The nonce rotates every 30 seconds and is erased
on stop; no device name, identity key, fingerprint or nickname is broadcast.
Flags remain zero until a reviewed SAS method is implemented. Discovery proves
compatibility only, not identity, freshness or proximity security.

Ordinary explicit discovery retains its 120-second Mac lifetime. A separate,
opt-in nearby-availability lifetime may remain active while the Mac process is
awake. It does not enable pairing writes or authenticated session admission.
Production onboarding wiring remains disabled until request admission, native
presentation and the SAS protocol are implemented together.

## Android signal policy

Use scan-local opaque candidate IDs and monotonic time. Keep at most 32 candidates
and the latest five valid RSSI samples per candidate, entirely in memory.
Accept only -126..-1 dBm; unavailable values must not refresh presence.

Qualify a candidate only after at least three samples and a median above -65 dBm
sustained for one second. A median below -72 dBm for three seconds removes
qualification; intermediate values retain current qualification. Missing valid
samples for five seconds discard the candidate and its smoothing history.
These thresholds are initial hardware-calibration values, not distance claims.
The owner schedules candidate expiry by the earliest monotonic deadline.

RSSI is an interruption/UX filter, never an authentication or relay defense.
Selection must freeze before a pairing exchange; signal changes must not
retarget it. Manual QR/PIN retains its authentication independent of RSSI.

## Activation gate

Before enabling onboarding, supply foreground/unlocked Android ownership,
known-empty active trust (not unreadable storage), radio exclusivity, bounded
global request admission, dismissal suppression and lifecycle cancellation.
First-pair availability stops after trusted pairing; additional devices use
explicit Add device. Never advertise support for an unimplemented SAS method.
