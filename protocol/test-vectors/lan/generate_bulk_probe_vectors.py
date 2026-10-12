#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Generates independent AES-GCM digest fixtures for the isolated bulk record profile.
import argparse
import hashlib
import json
from pathlib import Path
import struct
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def generate():
    key, iv, sid = bytes(range(32)), bytes(range(12)), bytes(range(32, 64))
    rows = []
    for length in (0, 65536, 4194304):
        plain = bytes(i % 251 for i in range(length))
        header = struct.pack('>BBQI', 2, 3, 0, length)
        sealed = AESGCM(key).encrypt(iv, plain, header + sid + b'\x01')
        record = header + sealed
        rows.append(dict(length=length, recordSHA256=hashlib.sha256(record).hexdigest(),
                         headerHex=header.hex(), tagHex=sealed[-16:].hex()))
    empty = struct.pack('>BBQI', 2, 3, 0, 0)
    record = empty + AESGCM(key).encrypt(iv, b'', empty + sid + b'\x01')
    invalid = []
    def add(name, value, reason):
        invalid.append(dict(name=name, recordHex=value.hex(), reason=reason))
    add('empty', b'', 'malformed')
    add('v1', b'\x01' + record[1:], 'malformed')
    add('unknown-version', b'\x03' + record[1:], 'malformed')
    add('unknown-kind', record[:1] + b'\x05' + record[2:], 'malformed')
    add('truncated', record[:-1], 'malformed')
    add('oversized-length', struct.pack('>BBQI', 2, 3, 0, 4194305) + bytes(16), 'malformed')
    add('unsigned-length', struct.pack('>BBQI', 2, 3, 0, 0xffffffff) + bytes(16), 'malformed')
    add('trailing', record + b'\x00', 'malformed')
    add('sequence', record[:2] + (1).to_bytes(8, 'big') + record[10:], 'authentication')
    add('tag', record[:-1] + bytes([record[-1] ^ 1]), 'authentication')
    return dict(keyHex=key.hex(), ivHex=iv.hex(), idHex=sid.hex(), valid=rows, invalid=invalid)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    target = Path(__file__).with_name('bulk-probe-vectors.json')
    encoded = json.dumps(generate(), indent=2) + '\n'
    if args.check:
        assert target.read_text() == encoded, 'Bulk probe fixtures differ from independent oracle'
        print('Bulk probe: 3 valid and 10 invalid independent AES-GCM fixtures passed')
    else:
        target.write_text(encoded)
