# SPDX-License-Identifier: GPL-3.0-or-later
# Defines independent big-endian TCP framing fixtures and verifies the checked-in inventory.
import argparse
import json
from pathlib import Path
import struct


def vectors():
    valid = []
    for size in (2, 17, 45, 118, 143, 4000, 4031, 4096):
        envelope = bytes([6]) + bytes(i % 256 for i in range(size - 1))
        valid.append(dict(name=f'length-{size}', envelopeHex=envelope.hex(),
                          frameHex=(struct.pack('>BI', 1, size) + envelope).hex()))
    invalid = []
    for version in (0, 2, 255):
        invalid.append(dict(name=f'version-{version}', frameHex=struct.pack('>BI', version, 2).hex(), reason='unsupportedProfile'))
    for length in (0, 1, 4097, 0xffffffff):
        invalid.append(dict(name=f'length-{length}', frameHex=struct.pack('>BI', 1, length).hex(), reason='malformed'))
    for name, frame in [('partial-header', b'\x01\x00\x00'),
                        ('partial-body', struct.pack('>BI', 1, 2) + b'\x06'),
                        ('trailing-header', struct.pack('>BI', 1, 2) + b'\x06\x00\x01')]:
        invalid.append(dict(name=name, frameHex=frame.hex(), reason='malformed'))
    return dict(valid=valid, invalid=invalid)


def oracle(wire):
    while wire:
        if wire[0] != 1:
            raise ValueError('unsupportedProfile')
        if len(wire) < 5:
            raise ValueError('malformed')
        _, length = struct.unpack('>BI', wire[:5])
        if not 2 <= length <= 4096 or len(wire) < 5 + length:
            raise ValueError('malformed')
        wire = wire[5 + length:]


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    rows = vectors()
    assert len(rows['valid']) >= 8 and len(rows['invalid']) >= 10
    for row in rows['valid']:
        oracle(bytes.fromhex(row['frameHex']))
    for row in rows['invalid']:
        try:
            oracle(bytes.fromhex(row['frameHex']))
        except ValueError as error:
            assert str(error) == row['reason']
        else:
            raise AssertionError(row['name'])
    destination = Path(__file__).with_name('lan-vectors.json')
    rendered = json.dumps(rows, indent=2) + '\n'
    if args.check:
        assert destination.read_text() == rendered, 'LAN fixture drift'
    else:
        destination.write_text(rendered)
    print('LAN fixtures: 8 valid, 10 invalid; independent struct oracle passed')
