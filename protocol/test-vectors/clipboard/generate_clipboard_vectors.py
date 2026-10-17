#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Independently encodes canonical clipboard fixtures and malformed boundary messages.
import argparse
import hashlib
import json
from pathlib import Path


def encode(value):
    def head(major, n):
        size = 0 if n < 24 else 1 if n < 256 else 2 if n < 65536 else 4 if n < 2**32 else 8
        return bytes([(major << 5) | (n if not size else {1: 24, 2: 25, 4: 26, 8: 27}[size])]) + (n.to_bytes(size, 'big') if size else b'')
    if isinstance(value, bool):
        return b'\xf5' if value else b'\xf4'
    if isinstance(value, int):
        return head(0 if value >= 0 else 1, value if value >= 0 else -1-value)
    if isinstance(value, str):
        data = value.encode('utf8')
        return head(3, len(data)) + data
    if isinstance(value, bytes):
        return head(2, len(value)) + value
    if isinstance(value, list):
        return head(4, len(value)) + b''.join(map(encode, value))
    raise TypeError(value)


def generate():
    epoch = '01234567-89ab-4cde-8fab-0123456789ab'
    item = '12345678-9abc-4def-8abc-123456789abc'
    def message(kind, fields):
        return ['aniCe clipboard', 1, kind, fields]
    def row(name, value):
        return {'name': name, 'bytesHex': encode(value).hex()}
    begin = [epoch, 1, item, 0, False, 5, 1, hashlib.sha256(b'hello').digest()]
    good = [row('capability', message(1, [epoch, 65536, 3072])), row('manual-settings', message(2, [1, False])),
            row('automatic-settings', message(2, [2**32-1, True])), row('begin', message(3, begin)),
            row('fragment', message(4, [item, 0, b'hello'])), row('commit', message(5, [item])), row('cancel', message(7, [item]))]
    good += [row('result-'+str(code), message(6, [item, code])) for code in range(8)]
    good += [row('max-fragment', message(4, [item, 21, b'x'*3072])),
             row('max-item-begin', message(3, [epoch, 2**32-1, item, 1, True, 65536, 22, hashlib.sha256(b'x'*65536).digest()])),
             row('unicode-fragment', message(4, [item, 0, 'नमस्ते 👋'.encode('utf8')]))]
    bad = [message(1, []), message(1, [epoch.upper(), 65536, 3072]), message(1, [epoch, 65537, 3072]),
           message(1, [epoch, 65536, 3073]), message(2, [0, True]), message(2, [2**32, True]), message(2, [1, 1]),
           message(3, begin[:-1]), message(4, [item, -1, b'x']), message(4, [item, 22, b'x']),
           message(4, [item, 0, b'']), message(4, [item, 0, b'x'*3073]), message(4, [item, 0, 'x']),
           message(5, ['bad']), message(5, [item, 1]), message(6, [item, 8]), message(6, [item, -1]),
           message(7, []), message(8, []), ['aniCe clipboard', 2, 1, [epoch, 65536, 3072]]]
    for index, value in [(0, 'bad'), (1, 0), (1, 2**32), (2, item.upper()), (3, 2), (4, 0), (5, 0), (5, 65537), (6, 2), (7, b'x'*31)]:
        changed = begin.copy(); changed[index] = value; bad.append(message(3, changed))
    invalid = [row('invalid-'+str(i), value) for i, value in enumerate(bad)]
    data = encode(message(5, [item]))
    invalid += [{'name': 'truncated', 'bytesHex': data[:-1].hex()}, {'name': 'trailing', 'bytesHex': (data+b'\0').hex()},
                {'name': 'nonminimal-version', 'bytesHex': data.hex().replace('640105', '64180105', 1)},
                {'name': 'invalid-utf8', 'bytesHex': (data[:-1]+b'\xff').hex()}]
    assert len(good) >= 18 and len(invalid) >= 34
    return {'valid': good, 'invalid': invalid}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
    path = Path(__file__).with_name('clipboard-vectors.json')
    content = json.dumps(generate(), indent=2)+'\n'
    if args.check:
        if path.read_text() != content:
            raise SystemExit('Clipboard fixtures differ; regenerate them.')
        print('Clipboard fixture inventory and canonical bytes passed.')
    else:
        path.write_text(content)
