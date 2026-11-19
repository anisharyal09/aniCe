#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generates independent canonical CBOR fixtures for authenticated pause notices."""
import argparse
import json
from pathlib import Path

import cbor2

TAG = "aniCe connection pause"
MAX_UNTIL = 253402300799999


def encode(row):
    return cbor2.dumps(row, canonical=True)


def parse(raw):
    if len(raw) > 128:
        raise ValueError("malformed")
    try:
        row = cbor2.loads(raw)
    except cbor2.CBORDecodeError as error:
        raise ValueError("malformed") from error
    if encode(row) != raw:
        raise ValueError("malformed")
    if type(row) is not list or not row or row[0] != TAG:
        return None
    if (len(row) != 4 or type(row[1]) is not int or row[1] != 1
            or type(row[2]) is not int or row[2] not in (1, 2)
            or type(row[3]) is not list or len(row[3]) != 1):
        raise ValueError("malformed")
    until = row[3][0]
    if type(until) is not int or not 0 <= until <= MAX_UNTIL or row[2] == 2 and until != 0:
        raise ValueError("malformed")
    return row[2], until


def vectors():
    pause = [TAG, 1, 1, [1800000300000]]
    valid = [
        ("indefinite", [TAG, 1, 1, [0]]),
        ("timed", pause),
        ("epoch-min", [TAG, 1, 1, [1]]),
        ("epoch-max", [TAG, 1, 1, [MAX_UNTIL]]),
        ("resume", [TAG, 1, 2, [0]]),
    ]
    raw = encode(pause)
    prefix = b"\x84" + encode(TAG)
    bad = [
        ("empty", b""), ("truncated", raw[:-1]), ("trailing", raw + b"\x00"),
        ("indefinite-array", b"\x9f" + raw[1:] + b"\xff"),
        ("nonminimal-version", prefix + b"\x18" + raw[len(prefix):]),
        ("unknown-version", encode([TAG, 2, 1, [0]])),
        ("boolean-version", encode([TAG, True, 1, [0]])),
        ("unknown-kind", encode([TAG, 1, 3, [0]])),
        ("zero-kind", encode([TAG, 1, 0, [0]])),
        ("boolean-kind", encode([TAG, 1, True, [0]])),
        ("missing-fields", encode([TAG, 1, 1])),
        ("extra-envelope-field", encode(pause + [0])),
        ("non-array-fields", encode([TAG, 1, 1, {}])),
        ("empty-fields", encode([TAG, 1, 1, []])),
        ("extra-field", encode([TAG, 1, 1, [0, 0]])),
        ("negative-time", encode([TAG, 1, 1, [-1]])),
        ("time-overflow", encode([TAG, 1, 1, [MAX_UNTIL + 1]])),
        ("boolean-time", encode([TAG, 1, 1, [True]])),
        ("text-time", encode([TAG, 1, 1, ["0"]])),
        ("null-time", encode([TAG, 1, 1, [None]])),
        ("float-time", encode([TAG, 1, 1, [1.0]])),
        ("resume-with-deadline", encode([TAG, 1, 2, [1]])),
        ("oversized", encode([TAG, 1, 1, ["x" * 128]])),
    ]
    positives = []
    for name, row in valid:
        payload = encode(row)
        kind, until = parse(payload)
        positives.append(dict(name=name, payloadHex=payload.hex(), kind=kind, untilMillis=until))
    negatives = []
    for name, payload in bad:
        try:
            parse(payload)
        except ValueError as error:
            negatives.append(dict(name=name, payloadHex=payload.hex(), reason=str(error)))
        else:
            raise AssertionError("Negative fixture accepted: " + name)
    unknown = encode(["another feature", 1, 1, [0]])
    assert parse(unknown) is None
    return dict(valid=positives, invalid=negatives,
                unrecognized=[dict(name="other-tag", payloadHex=unknown.hex())])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rows = vectors()
    path = Path(__file__).with_name("vectors.json")
    rendered = json.dumps(rows, indent=2) + "\n"
    if args.check:
        assert path.read_text() == rendered, "Pause fixtures differ from their independent oracle"
    else:
        path.write_text(rendered)
    print(f"Connection pause: {len(rows['valid'])} valid / {len(rows['invalid'])} invalid")
