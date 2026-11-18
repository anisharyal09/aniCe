#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generates independent cbor2/IP-address fixtures for BLE rendezvous and LAN renewal controls."""
import argparse
import ipaddress
import json
from pathlib import Path

import cbor2


def encode(row):
    return cbor2.dumps(row, canonical=True)


def parse(raw, tag, maximum):
    if len(raw) > maximum:
        raise ValueError("malformed")
    try:
        row = cbor2.loads(raw)
    except cbor2.CBORDecodeError as error:
        raise ValueError("malformed") from error
    if encode(row) != raw or type(row) is not list or not row or row[0] != tag:
        raise ValueError("malformed")
    return row


def rendezvous(raw):
    row = parse(raw, "aniCe LAN", 64)
    if len(row) not in (3, 4) or type(row[1]) is not int or type(row[2]) is not int:
        raise ValueError("malformed")
    version, state = row[1:3]
    if version not in (1, 2) or state not in range(5 if version == 1 else 6) or len(row) != version + 2:
        raise ValueError("malformed")
    if version == 2:
        fields = row[3]
        if type(fields) is not list or len(fields) not in (0, 3) or fields and state != 2:
            raise ValueError("malformed")
        if fields:
            ip, port, profile = fields
            try:
                address = ipaddress.IPv4Address(ip) if type(ip) is str else None
            except ipaddress.AddressValueError as error:
                raise ValueError("malformed") from error
            if (address is None or str(address) != ip or address.packed[0] in (0, 127)
                    or address.packed[0] >= 224 or type(port) is not int or not 1 <= port <= 65535
                    or type(profile) is not int or profile not in (1, 3, 4)):
                raise ValueError("malformed")
    return version, state


def renewal(raw):
    row = parse(raw, "aniCe LAN renewal", 128)
    if len(row) != 4 or type(row[1]) is not int or type(row[2]) is not int:
        raise ValueError("malformed")
    if row[1] != 1 or row[2] not in (1, 2, 3):
        raise ValueError("unsupportedProfile")
    kind, fields = row[2:4]
    if type(fields) is not list or len(fields) != {1: 0, 2: 2, 3: 1}[kind]:
        raise ValueError("malformed")
    if kind != 1 and (type(fields[0]) is not bytes or len(fields[0]) != 16):
        raise ValueError("malformed")
    if kind == 2 and (type(fields[1]) is not int or fields[1] not in (1, 2)):
        raise ValueError("malformed")
    return kind


def fixtures(valid, invalid, oracle):
    positives = [dict(name=name, payloadHex=encode(row).hex()) for name, row in valid]
    negatives = []
    for name, raw in invalid:
        try:
            oracle(raw)
        except ValueError as error:
            negatives.append(dict(name=name, payloadHex=raw.hex(), reason=str(error)))
        else:
            raise AssertionError("Negative fixture accepted: " + name)
    for row in positives:
        oracle(bytes.fromhex(row["payloadHex"]))
    assert len(positives) >= 4 and len(negatives) >= 15
    return dict(valid=positives, invalid=negatives)


def canonical_faults(row):
    raw = encode(row)
    prefix = b"\x84" + encode(row[0])
    return [
        ("empty", b""), ("truncated", raw[:-1]), ("trailing", raw + b"\x00"),
        ("indefinite", b"\x9f" + raw[1:] + b"\xff"),
        ("nonminimal-version", prefix + b"\x18" + raw[len(prefix):]),
        ("wrong-tag", encode(["other"] + row[1:])),
        ("extra-field", encode(row + [0])),
        ("boolean-version", encode([row[0], True] + row[2:])),
        ("boolean-type", encode(row[:2] + [True] + row[3:])),
        ("unknown-version", encode([row[0], 9] + row[2:])),
        ("unknown-type", encode(row[:2] + [9] + row[3:])),
        ("non-array-fields", encode(row[:3] + [{}])),
        ("oversized", encode(row[:3] + [["x" * 128]])),
        ("float", encode(row[:2] + [1.0] + row[3:])),
        ("null", encode(row[:3] + [None])),
    ]


def vectors():
    endpoint = ["192.0.2.10", 51234, 4]
    ready = ["aniCe LAN", 2, 2, endpoint]
    valid = [(f"v1-state-{state}", ["aniCe LAN", 1, state]) for state in range(5)]
    valid += [(f"v2-state-{state}", ["aniCe LAN", 2, state, []]) for state in range(6)]
    valid += [(f"profile-{profile}", ready[:3] + [[endpoint[0], endpoint[1], profile]])
              for profile in (1, 3, 4)]
    valid += [("port-min", ready[:3] + [[endpoint[0], 1, 4]]),
              ("port-max", ready[:3] + [[endpoint[0], 65535, 4]])]
    bad = canonical_faults(ready)
    for ip in ("127.0.0.1", "0.0.0.0", "0.2.3.4", "224.0.0.1", "255.255.255.255",
               "192.168.01.1", "192.168.1.256", "localhost", "192.0.2", "::1", "1.2.3.4%5"):
        bad.append((f"ip-{ip}", encode(ready[:3] + [[ip, 51234, 4]])))
    for name, fields in [("port-zero", [endpoint[0], 0, 4]),
                         ("port-overflow", [endpoint[0], 65536, 4]),
                         ("port-bool", [endpoint[0], True, 4]),
                         ("profile-probe", [endpoint[0], 51234, 2]),
                         ("profile-bool", [endpoint[0], 51234, True]),
                         ("short-endpoint", endpoint[:2])]:
        bad.append((name, encode(ready[:3] + [fields])))
    bad += [("endpoint-in-state-1", encode(["aniCe LAN", 2, 1, endpoint])),
            ("endpoint-in-user-demand", encode(["aniCe LAN", 2, 5, endpoint])),
            ("v1-user-demand", encode(["aniCe LAN", 1, 5])),
            ("v2-unknown-state", encode(["aniCe LAN", 2, 6, []])),
            ("v1-with-fields", encode(["aniCe LAN", 1, 2, []])),
            ("v2-without-fields", encode(["aniCe LAN", 2, 2]))]
    automatic = fixtures(valid, bad, rendezvous)
    token = bytes(range(16))
    begin = ["aniCe LAN renewal", 1, 2, [token, 1]]
    valid = [("support", ["aniCe LAN renewal", 1, 1, []]),
             ("lifetime", begin),
             ("record-margin", begin[:3] + [[token, 2]]),
             ("drained", ["aniCe LAN renewal", 1, 3, [token]])]
    bad = canonical_faults(begin)
    for name, fields in [("short-id", [token[:-1], 1]), ("long-id", [token + b"\x00", 1]),
                         ("text-id", ["a" * 16, 1]), ("reason-zero", [token, 0]),
                         ("reason-three", [token, 3]), ("reason-bool", [token, True])]:
        bad.append((name, encode(begin[:3] + [fields])))
    bad += [("support-with-id", encode(["aniCe LAN renewal", 1, 1, [token]])),
            ("drained-with-reason", encode(["aniCe LAN renewal", 1, 3, [token, 1]]))]
    return {"automatic-vectors.json": automatic,
            "renewal-vectors.json": fixtures(valid, bad, renewal)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for name, rows in vectors().items():
        path = Path(__file__).with_name(name)
        rendered = json.dumps(rows, indent=2) + "\n"
        if args.check:
            assert path.read_text() == rendered, name + " differs from its independent oracle"
        else:
            path.write_text(rendered)
        print(f"{name}: {len(rows['valid'])} valid / {len(rows['invalid'])} invalid")
