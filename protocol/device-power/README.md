# Device Power v1

Device Power shares each device's battery status with its connected, trusted peer so device-status surfaces can show charging and percentage. It uses an existing secured DATA channel and never starts or extends a background connection lease. Each publisher listens for power changes only while a secured peer channel exists, sends its current reading when a channel becomes available, and coalesces unsent updates to the latest value. Older Android clients ignore Mac reports; older Macs do not publish them.

The deterministic CBOR envelope is `["aniCe device power", 1, kind, fields]`. Records are at most 128 bytes.

| Kind | Direction | Fields |
| --- | --- | --- |
| 1 capability | Either direction | `[1]` |
| 2 report | Either direction | `[state, percent, source]` |

`state` is unavailable `0`, no battery `1`, on battery `2`, charging `3`, fully charged `4`, or plugged in but not charging `5`. `percent` is `-1` when unknown or no battery is present, otherwise `0..100`. `source` is unavailable `0`, battery `1`, AC `2`, USB `3`, wireless `4`, or dock `5`. Unknown percentage is valid for a known battery state; clients must display it as unavailable rather than estimating it. An unrecognized external power source is reported as unavailable rather than mislabeled as AC.

Each device accepts reports only after capability from the same trusted peer and channel. It clears the reading after that peer's last secured channel retires. The capability is independent of Desk Deck, so Mac overview and Android Home and Devices can show peer power without opening Desk Deck. On Mac, an unrecognized source, including UPS, is reported as unavailable rather than being labeled USB.

See [`device-power.cddl`](device-power.cddl) and the shared [positive and negative fixtures](../test-vectors/device-power-vectors.json).
