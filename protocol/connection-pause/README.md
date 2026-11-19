<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Connection pause notice v1

A device can announce a local automatic-connection pause over an already secured BLE or LAN channel before closing its connections. The notice describes the sender's policy; it does not authorize connections, create a background lease or change the receiver's saved preferences.

## Envelope

Deterministic CBOR inside application DATA kind 3 / session envelope 6, at most 128 bytes. The [schema](connection-pause.cddl) defines:

| Kind | Envelope | Meaning |
| --- | --- | --- |
| 1 | `["aniCe connection pause", 1, 1, [untilMillis]]` | Sender paused until the stated UTC Unix epoch milliseconds; `0` means until locally resumed. |
| 2 | `["aniCe connection pause", 1, 2, [0]]` | Sender resumed its local pause. |

`untilMillis` is an integer in `0..253402300799999`. Exact version, kind, field count, integer types and canonical encoding are required. Unknown tags remain unrecognized DATA; invalid notices are discarded without retiring the shared session. Older peers can ignore this additive tag. It is not a session control opcode.

## Sending and teardown

Pause gates local automatic attempts and new candidate admission immediately. Unfinished connection setup retires at once; only already-secured channels remain available for a best-effort submission, preferring LAN and falling back to BLE. There is no offline queue, retry after teardown or acknowledgement requirement. Teardown proceeds after submission or a one-second notice budget, even if DATA capacity is unavailable. Native close retains its existing separate bounded cleanup.

Resume, explicit Connect, a newer pause, ownership loss and trust/identity invalidation supersede pending teardown. A delayed notice completion cannot close a replacement connection. Successfully sealed records are never replayed.

## Receiver presentation

Only a current authenticated channel can supply a notice. The receiver shows **Paused on &lt;device&gt;**, optionally with the deadline, for that full peer credential. The notice survives retirement of that channel in memory, but not an app restart.

An expired notice, a resumed notice, a fresh secured channel for that peer, local Resume/explicit Connect or trust/identity invalidation clears it. Duplicate notices do not extend the supplied deadline; receivers retain at most sixteen peer notices. Clock changes are reevaluated against wall time.

The receiver does not echo notices or pause its own automatic policy. In particular, pausing Android's central as a side effect of a Mac notice would prevent a Mac-side Resume from accepting a fresh BLE connection. Local automatic choices and native ownership remain independent. Pause/resume notices are not ordinary feature demand for automatic LAN.

## Fixtures

[Shared fixtures](../test-vectors/connection-pause/vectors.json) cover timed/indefinite pause, resume and rejected encodings. The adjacent `generate.py --check` uses an independent CBOR oracle.
