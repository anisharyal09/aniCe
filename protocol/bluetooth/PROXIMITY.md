<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Nearby pairing discovery and availability

Numeric comparison uses [pairing method 3](../pairing/SAS.md), a provisional
application-layer SAS contract requiring independent security review.
Mac remains the peripheral; Android remains the central. No bonding is requested.

## Anonymous availability

The advertisement remains the public aniCe service UUID and optional generic name.
Apple's peripheral advertising API does not provide arbitrary service/manufacturer
payloads. The existing 20-byte discovery characteristic retains its version,
flags and random nonce layout. The nonce rotates every 30 seconds and is erased
on stop; no device name, identity key, fingerprint or nickname is broadcast.
Flag `0x0001` offers numeric comparison during Mac nearby availability; ordinary
discovery and QR/PIN keep flags zero. Discovery proves compatibility only, not
identity, freshness or proximity security.

Ordinary explicit discovery retains its 120-second Mac lifetime. A separate,
nearby-availability lifetime remains active while the Mac process is awake and
unlocked, after successfully loaded empty active trust. Mac offers explicit
Find nearby and Pause controls. Its pairing owner admits one globally rate-limited
candidate through the existing GATT channels; discovery never authorizes a session.
Generic nearby advertising stops when a pairing candidate takes the slot. Already
admitted pairing reads/writes and replies do not depend on advertising afterward.
After retirement, re-advertise only once the global admission spacing/budget and
dismissal deadline permit another attempt. The native availability presentation
shows cooldown instead of advertising a request it cannot admit; explicit Find
nearby cannot clear these limits.
Android Home scans while foreground and unlocked with
successfully loaded empty trust, granted permissions and no pairing/discovery
operation. First unpaired/resumed Home may request native discovery permission
once; denial and subsequent foreground return never repeatedly launch that dialog.
Permission is not trust, comparison confirmation or companion ownership.
Exactly one qualified beacon, unchanged through a 750-ms ambiguity
check, automatically prepares comparison once. Multiple qualified candidates
require explicit selection with Compare code, even if one later disappears.
Selection freezes one native locator, stops scanning and hands it to the existing
bounded GATT owner. Require availability flag `0x0001` after discovery read and
never automatically downgrade or select another locator. Dismiss suppresses
automatic prompts and exchanges until Find nearby is tapped. A failed exchange
requires Try again after verification has begun. A pre-authentication transport
failure may restart discovery twice at least ten seconds apart, without clearing
Mac admission limits. Dismissal still requires explicit Find nearby.
Manual pair retains QR/PIN compatibility with older peers. Nearby automatic
discovery stops after the first trusted pairing; additional peers use Add device.
Closing the Mac window leaves process-owned availability running; Quit stops it.

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

## Lifecycle and verification

Foreground/unlocked Android ownership, known-empty active trust (not unreadable
storage), radio exclusivity, bounded global request admission, dismissal suppression
and lifecycle cancellation are mandatory. Per-attempt crypto/comparison deadlines
are separate from the availability lifetime. Unknown names stay generic through
comparison confirmation. See the SAS contract for identity commitments, receipts
and admission limits. Real hardware acceptance includes signal calibration,
lock/sleep cancellation, native card focus and mutual comparison confirmation.

Android comparison visibility must subscribe to the selected method and phase
even when the initial method is QR/idle. The global comparison prompt and the
Add device surface share the same attempt/code/actions. Confirm/decline callbacks
must reject retired attempt IDs; changing presentation alone never sends either
approval or cancellation.
