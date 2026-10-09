#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent cbor2 oracle for the bounded application-control contract."""
import argparse
import json
from pathlib import Path

import cbor2


def encode(value):
    return cbor2.dumps(value, canonical=True)


def validate(raw):
    if len(raw) > 128:
        raise ValueError("malformed")
    try:
        row = cbor2.loads(raw)
    except cbor2.CBORDecodeError as error:
        raise ValueError("malformed") from error
    if encode(row) != raw or type(row) is not list or len(row) != 4 or row[0] != "aniCe control":
        raise ValueError("malformed")
    if type(row[1]) is not int or type(row[2]) is not int:
        raise ValueError("malformed")
    if row[1] != 1 or row[2] not in range(1, 6):
        raise ValueError("unsupportedProfile")
    key = "version" if row[2] <= 2 else "requestId" if row[2] <= 4 else "reason"
    if type(row[3]) is not dict or set(row[3]) != {key} or type(row[3][key]) is not int:
        raise ValueError("malformed")
    value = row[3][key]
    if not (value == 1 if row[2] <= 2 else 0 <= value <= 0xffffffff if row[2] <= 4 else value in (1, 2)):
        raise ValueError("malformed")
    return row[2], value


def vectors():
    def row(kind=1, value=1, version=1, tag="aniCe control"):
        key = "version" if kind <= 2 else "requestId" if kind <= 4 else "reason"
        return [tag, version, kind, {key: value}]
    valid = [{"type": t, "value": v, "payloadHex": encode(row(t, v)).hex()}
             for t, v in [(1, 1), (2, 1), (3, 0), (3, 0xffffffff), (4, 0), (4, 0xffffffff), (5, 1), (5, 2)]]
    hello = encode(row())
    prefix = b"\x84" + encode("aniCe control")
    map_start = len(prefix) + 2
    invalid = [
        ("empty", b""), ("truncated", hello[:-1]), ("trailing", hello + b"\x00"),
        ("indefinite-array", b"\x9f" + hello[1:] + b"\xff"),
        ("nonminimal-version", prefix + b"\x18\x01" + hello[len(prefix) + 1:]),
        ("nonminimal-map-length", hello[:map_start] + b"\xb8\x01" + hello[map_start + 1:]),
        ("duplicate-key", hello[:map_start] + b"\xa2" + hello[map_start + 1:] * 2),
        ("oversized", encode(["aniCe control", 1, 1, {"version": "a" * 128}])),
        ("wrong-tag", encode(row(tag="other"))), ("wrong-arity", encode(row() + [0])),
        ("unknown-version", encode(row(version=2))), ("boolean-version", encode(row(version=True))),
        ("unknown-type", encode(["aniCe control", 1, 6, {"reason": 1}])),
        ("boolean-type", encode(["aniCe control", 1, True, {"version": 1}])),
        ("extra-key", encode(["aniCe control", 1, 1, {"version": 1, "extra": 0}])),
        ("missing-key", encode(["aniCe control", 1, 1, {}])),
        ("wrong-key", encode(["aniCe control", 1, 1, {"requestId": 1}])),
        ("boolean-value", encode(row(value=True))), ("float-value", encode(row(value=1.0))),
        ("wrong-hello-version", encode(row(value=2))), ("negative-id", encode(row(3, -1))),
        ("overflow-id", encode(row(4, 0x100000000))), ("wrong-reason-zero", encode(row(5, 0))),
        ("wrong-reason-three", encode(row(5, 3))),
        ("non-map", encode(["aniCe control", 1, 1, [1]])),
        ("invalid-text", hello[:3] + b"\xff" + hello[4:]),
    ]
    negatives = []
    for name, raw in invalid:
        try:
            validate(raw)
        except ValueError as error:
            negatives.append({"name": name, "payloadHex": raw.hex(), "reason": str(error)})
        else:
            raise AssertionError(f"negative accepted: {name}")
    assert len(valid) >= 3 and len(negatives) >= 15
    for fixture in valid:
        assert validate(bytes.fromhex(fixture["payloadHex"])) == (fixture["type"], fixture["value"])
    return {"valid": valid, "invalid": negatives}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    path = Path(__file__).with_name("control-vectors.json")
    content = json.dumps(vectors(), indent=2) + "\n"
    if args.check:
        assert path.read_text() == content, "control vectors differ from the independent oracle"
    else:
        path.write_text(content)
    print("8 valid / 26 invalid control fixtures verified")
