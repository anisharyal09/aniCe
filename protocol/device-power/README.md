# Device Power v1

Device Power sends an Android phone's current battery status to a connected, trusted Mac so existing device-status surfaces can show charging and percentage. It uses the secured DATA channel already open for the peer and never starts or extends a background connection lease. The Android publisher listens for battery changes only while at least one secured peer channel exists, sends the current reading on channel availability, and coalesces unsent updates to the latest value.

The deterministic CBOR envelope is `["aniCe device power", 1, kind, fields]`. Records are at most 128 bytes.

| Kind | Direction | Fields |
| --- | --- | --- |
| 1 capability | Android → Mac | `[1]` |
| 2 report | Android → Mac | `[state, percent, source]` |

`state` is unavailable `0`, no battery `1`, on battery `2`, charging `3`, fully charged `4`, or plugged in but not charging `5`. `percent` is `-1` when unknown or no battery is present, otherwise `0..100`. `source` is unavailable `0`, battery `1`, AC `2`, USB `3`, wireless `4`, or dock `5`. Unknown percentage is valid for a known battery state; clients must display it as unavailable rather than estimating it. An unrecognized external power source is reported as unavailable rather than mislabeled as AC.

Mac accepts reports only after capability from the same trusted peer and channel. It clears the cached reading after the peer's last secured channel retires. The capability is independent of Desk Deck, so the Mac overview and menu-bar companion can show phone power without opening Desk Deck.

See [`device-power.cddl`](device-power.cddl) and the shared [positive and negative fixtures](../test-vectors/device-power-vectors.json).
