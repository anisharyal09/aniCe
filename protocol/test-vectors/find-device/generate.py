# SPDX-License-Identifier: GPL-3.0-or-later
# Independently encodes canonical and adversarial Find Device fixture inventories.
import json
from pathlib import Path


def encode(value):
    def head(major, n):
        if n < 24:
            return bytes([(major << 5) | n])
        size = 1 if n < 256 else 2 if n < 65536 else 4 if n < 2**32 else 8
        return bytes([(major << 5) | {1: 24, 2: 25, 4: 26, 8: 27}[size]]) + n.to_bytes(size, 'big')
    if isinstance(value, int):
        return head(0 if value >= 0 else 1, value if value >= 0 else -1-value)
    if isinstance(value, str):
        data = value.encode('utf8')
        return head(3, len(data)) + data
    if isinstance(value, list):
        return head(4, len(value)) + b''.join(map(encode, value))
    raise TypeError(value)


def generate():
    tag = 'aniCe find device'
    request = '01234567-89ab-4cde-8fab-0123456789ab'
    def row(name, value):
        return {'name': name, 'kind': value[2], 'bytesHex': encode(value).hex()}
    good = [row('capability', [tag, 1, 1, []]), row('request', [tag, 1, 2, [request, 1]]),
            row('max-sequence', [tag, 1, 2, [request, 2**32-1]])]
    good += [row('result-'+str(result), [tag, 1, 3, [request, 1, result]]) for result in range(5)]
    bad_values = [
        [tag, 2, 1, []], [tag, 1, 0, []], [tag, 1, 4, []], [tag, 1, 1, [1]],
        [tag, 1, 2, [request]], [tag, 1, 2, [request, 0]], [tag, 1, 2, [request, -1]],
        [tag, 1, 2, [request, 2**32]], [tag, 1, 2, [request.upper(), 1]],
        [tag, 1, 2, ['bad', 1]], [tag, 1, 2, [request, '1']], [tag, 1, 2, [1, 1]],
        [tag, 1, 2, [request, 1, 0]], [tag, 1, 3, [request, 1]],
        [tag, 1, 3, [request, 1, -1]], [tag, 1, 3, [request, 1, 5]],
        [tag, 1, 3, [request, 1, '0']], [tag, 1, 3, [request, 1, 0, 0]],
        [tag, 1, 1], [tag, 1, 1, [], 0], [tag, 1, 2, ['x'*150, 1]],
    ]
    bad = [row('invalid-'+str(i), value) for i, value in enumerate(bad_values)]
    data = encode([tag, 1, 2, [request, 1]])
    bad += [{'name': 'truncated', 'bytesHex': data[:-1].hex()},
            {'name': 'trailing', 'bytesHex': (data+b'\x00').hex()},
            {'name': 'nonminimal', 'bytesHex': (data[:-1]+b'\x18\x01').hex()}]
    return {'valid': good, 'invalid': bad}


if __name__ == '__main__':
    Path(__file__).with_name('find-device-vectors.json').write_text(json.dumps(generate(), indent=2)+'\n')
