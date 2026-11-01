#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Generates independent AES-GCM digest fixtures for isolated bulk and production LAN profiles.
import argparse
import hashlib
import json
from pathlib import Path
import struct
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def generate(lan_transfer=False, lan_512=False):
    wire, maximum = (4, 524416) if lan_512 else (3, 262144) if lan_transfer else (2, 4194304)
    key, iv, sid = bytes(range(32)), bytes(range(12)), bytes(range(32, 64))
    rows = []
    for length in (0, 65536, maximum):
        plain = bytes(i % 251 for i in range(length))
        header = struct.pack('>BBQI', wire, 3, 0, length)
        sealed = AESGCM(key).encrypt(iv, plain, header + sid + b'\x01')
        record = header + sealed
        rows.append(dict(length=length, recordSHA256=hashlib.sha256(record).hexdigest(),
                         headerHex=header.hex(), tagHex=sealed[-16:].hex()))
    empty = struct.pack('>BBQI', wire, 3, 0, 0)
    record = empty + AESGCM(key).encrypt(iv, b'', empty + sid + b'\x01')
    invalid = []
    def add(name, value, reason):
        invalid.append(dict(name=name, recordHex=value.hex(), reason=reason))
    add('empty', b'', 'malformed')
    add('v1', b'\x01' + record[1:], 'malformed')
    add('unknown-version', bytes([wire + 1]) + record[1:], 'malformed')
    add('unknown-kind', record[:1] + b'\x05' + record[2:], 'malformed')
    add('truncated', record[:-1], 'malformed')
    add('oversized-length', struct.pack('>BBQI', wire, 3, 0, maximum + 1) + bytes(16), 'malformed')
    add('unsigned-length', struct.pack('>BBQI', wire, 3, 0, 0xffffffff) + bytes(16), 'malformed')
    add('trailing', record + b'\x00', 'malformed')
    add('sequence', record[:2] + (1).to_bytes(8, 'big') + record[10:], 'authentication')
    add('tag', record[:-1] + bytes([record[-1] ^ 1]), 'authentication')
    return dict(keyHex=key.hex(), ivHex=iv.hex(), idHex=sid.hex(), valid=rows, invalid=invalid)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--lan-transfer', action='store_true')
    parser.add_argument('--lan-512', action='store_true')
    args = parser.parse_args()
    target = Path(__file__).with_name('lan-512-vectors.json' if args.lan_512 else 'lan-transfer-vectors.json' if args.lan_transfer else 'bulk-probe-vectors.json')
    encoded = json.dumps(generate(args.lan_transfer, args.lan_512), indent=2) + '\n'
    if args.check:
        assert target.read_text() == encoded, 'Bulk probe fixtures differ from independent oracle'
        print(('LAN 512' if args.lan_512 else 'LAN transfer' if args.lan_transfer else 'Bulk probe') + ': 3 valid and 10 invalid independent AES-GCM fixtures passed')
    else:
        target.write_text(encoded)
