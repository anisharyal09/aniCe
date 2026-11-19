<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Foreground companion setup v1

After trusted pairing and fresh BLE readiness, foreground Android may offer native
companion enrollment for the **currently authenticated Mac**. The system chooser
still requires user approval; the association is a locator/background lease, never
trust or Bluetooth bonding. A process-local target freezes the full peer credential,
current channel instance and native BLE address for at most sixty seconds. Addresses
are not supplied by the wire or shown in app UI.

Mac normally stops advertising when its one BLE slot is occupied. Enrollment can
request a short advertisement window on the **same peripheral manager and existing
generic service**. The admitted central remains the sole application owner; the
window does not reopen admission, reset counters, or replace the channel.

Deterministic CBOR inside existing secured DATA, maximum 128 bytes:
`["aniCe companion setup", 1, kind, fields]`.

| kind | direction | fields |
| --- | --- | --- |
| 1 | either | `[1]` capability |
| 2 | Android → Mac | `[seconds]`, exactly `0` (end) or `60` (begin) |
| 3 | Mac → Android | `[available]`, boolean acknowledgment |

Require same-channel capability, expected direction and an already-ready pinned
BLE connection. Unknown tags are unrecognized; malformed recognized messages are
discarded. Android waits up to five seconds for capability and acknowledgment.
No periodic scan/retry or new background service is introduced. The window expires
after sixty monotonic seconds or earlier on cancellation, completion, disconnect,
sleep or Quit. Duplicate begins do not extend the active deadline. Mac uses no
device name or identity in advertising. Physical advertising is best effort.

Acknowledgment means the bounded request was accepted, not proof that the OS has
started emitting packets. Native advertising callbacks retain their generation
gate and must not reopen session admission. Both platforms verify the deterministic
capability/request/ack bytes in their regression suites.

Only explicit foreground enrollment creates a bounded Android connection lease
while the native chooser temporarily backgrounds the activity. Screen lock still
retires unowned access; native companion approval and pinned revalidation remain
required. The single-device OS request filters the frozen BLE address and aniCe
service. A stale/replaced target or differing returned locator must not arm setup;
remove a newly created association from that failed attempt. Older peers retain
manual connections and the existing full setup/repair path.
