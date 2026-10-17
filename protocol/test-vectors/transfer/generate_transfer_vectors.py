# SPDX-License-Identifier: GPL-3.0-or-later
# Generates independent deterministic CBOR file transfer fixtures for both native codecs.
import argparse
import json, copy
from pathlib import Path

# Independent RFC 8949 encoder; deliberately does not import application codecs.
def head(m, n):
    if n < 24:
        return bytes([m * 32 + n])
    for size, tag in [(1, 24), (2, 25), (4, 26), (8, 27)]:
        if n < 1 << (8 * size):
            return bytes([m * 32 + tag]) + n.to_bytes(size, 'big')

def enc(v):
    if isinstance(v, bool):
        return b'\xf5' if v else b'\xf4'
    if isinstance(v, int):
        return head(0, v) if v >= 0 else head(1, -1 - v)
    if isinstance(v, str):
        v = v.encode('utf-8')
        return head(3, len(v)) + v
    if isinstance(v, bytes):
        return head(2, len(v)) + v
    if isinstance(v, list):
        return head(4, len(v)) + b''.join(enc(x) for x in v)
    raise ValueError(v)

batch_id = '11111111-1111-4111-8111-111111111111'
file_id1 = '22222222-2222-4222-8222-222222222222'
file_id2 = '33333333-3333-4333-8333-333333333333'
sha256_mock = bytes([0xaa] * 32)

def msg(kind, fields, version=1):
    return ['aniCe transfer', version, kind, fields]

file_entry1 = [file_id1, 'report.pdf', 1048576, sha256_mock]
file_entry2 = [file_id2, 'image 📷.png', 524288, sha256_mock]

valid = [
    ('capability', msg(1, [1, 3072, 64])),
    ('offer-single', msg(2, [batch_id, 0, 1, 1, 1048576, [file_entry1]])),
    ('offer-multi', msg(2, [batch_id, 0, 1, 2, 1572864, [file_entry1, file_entry2]])),
    ('accept-all', msg(3, [batch_id, []])),
    ('accept-specific', msg(3, [batch_id, [file_id1]])),
    ('reject-declined', msg(4, [batch_id, 0])),
    ('reject-space', msg(4, [batch_id, 2])),
    ('chunk-initial', msg(5, [batch_id, file_id1, 0, bytes([0x42] * 3072)])),
    ('chunk-small', msg(5, [batch_id, file_id1, 3072, b'hello world'])),
    ('ack', msg(6, [batch_id, file_id1, 49152])),
    ('file-result-success', msg(7, [batch_id, file_id1, 0, sha256_mock])),
    ('file-result-mismatch', msg(7, [batch_id, file_id1, 1, sha256_mock])),
    ('batch-result-success', msg(8, [batch_id, 0])),
    ('batch-result-partial', msg(8, [batch_id, 1])),
    ('cancel-file', msg(9, [batch_id, file_id1, 0])),
    ('cancel-batch', msg(9, [batch_id, '', 0])),
    ('resume', msg(10, [batch_id, file_id1, 65536, sha256_mock])),
    ('status-transferring', msg(11, [batch_id, file_id1, 65536, 1])),
    ('status-batch-level', msg(11, [batch_id, '', 1048576, 1])),
]

invalid = [
    ('bad-version', msg(1, [1, 3072, 64], version=2)),
    ('unknown-kind', msg(99, [batch_id])),
    ('short-capability', msg(1, [1, 3072])),
    ('bad-capability-chunk', msg(1, [1, 3073, 64])),
    ('bad-capability-window', msg(1, [1, 3072, 65])),
    ('offer-slice-overflow', msg(2, [batch_id, 1, 1, 1, 1048576, [file_entry1]])),
    ('offer-zero-slices', msg(2, [batch_id, 0, 0, 1, 1048576, [file_entry1]])),
    ('offer-zero-files', msg(2, [batch_id, 0, 1, 0, 0, []])),
    ('offer-bad-uuid', msg(2, ['invalid-uuid', 0, 1, 1, 1048576, [file_entry1]])),
    ('offer-filename-traversal', msg(2, [batch_id, 0, 1, 1, 1048576, [[file_id1, '../etc/passwd', 10, sha256_mock]]])),
    ('offer-filename-slash', msg(2, [batch_id, 0, 1, 1, 1048576, [[file_id1, 'sub/folder.txt', 10, sha256_mock]]])),
    ('offer-filename-nul', msg(2, [batch_id, 0, 1, 1, 1048576, [[file_id1, 'file\0.txt', 10, sha256_mock]]])),
    ('offer-filename-empty', msg(2, [batch_id, 0, 1, 1, 1048576, [[file_id1, '', 10, sha256_mock]]])),
    ('offer-filename-too-long', msg(2, [batch_id, 0, 1, 1, 1048576, [[file_id1, 'a' * 256, 10, sha256_mock]]])),
    ('offer-negative-size', msg(2, [batch_id, 0, 1, 1, -1, [[file_id1, 'a.txt', -1, sha256_mock]]])),
    ('offer-short-hash', msg(2, [batch_id, 0, 1, 1, 10, [[file_id1, 'a.txt', 10, bytes([1] * 31)]]])),
    ('accept-bad-batch', msg(3, ['not-a-uuid', []])),
    ('accept-bad-file-id', msg(3, [batch_id, ['bad-uuid']])),
    ('reject-unknown-reason', msg(4, [batch_id, 5])),
    ('chunk-oversized', msg(5, [batch_id, file_id1, 0, bytes(3073)])),
    ('chunk-zero-bytes', msg(5, [batch_id, file_id1, 0, b''])),
    ('chunk-negative-offset', msg(5, [batch_id, file_id1, -1, b'abc'])),
    ('ack-negative-offset', msg(6, [batch_id, file_id1, -1])),
    ('file-result-unknown-code', msg(7, [batch_id, file_id1, 4, sha256_mock])),
    ('file-result-bad-hash', msg(7, [batch_id, file_id1, 0, bytes(31)])),
    ('batch-result-unknown-code', msg(8, [batch_id, 4])),
    ('cancel-unknown-reason', msg(9, [batch_id, '', 5])),
    ('resume-negative-offset', msg(10, [batch_id, file_id1, -1, sha256_mock])),
    ('resume-bad-hash', msg(10, [batch_id, file_id1, 0, bytes(33)])),
    ('status-unknown-state', msg(11, [batch_id, file_id1, 0, 5])),
]

out = {
    'oracle': 'Independent Python RFC 8949 encoder; no native codec imports',
    'valid': [{'name': n, 'bytesHex': enc(v).hex(), 'kind': v[2]} for n, v in valid],
    'invalid': [{'name': n, 'bytesHex': enc(v).hex()} for n, v in invalid]
}

# Add structural wire corruptions
out['invalid'] += [
    {'name': 'truncated-envelope', 'bytesHex': enc(msg(1, [1, 3072, 64])).hex()[:-2]},
    {'name': 'noncanonical-integer', 'bytesHex': (b'\x84' + enc('aniCe transfer') + b'\x18\x01' + enc(1) + enc([1, 3072, 64])).hex()},
    {'name': 'oversized-record', 'bytesHex': enc(msg(5, [batch_id, file_id1, 0, bytes(3950)])).hex()}
]

assert len(out['valid']) >= 12, f"Expected at least 12 valid fixtures, found {len(out['valid'])}"
assert len(out['invalid']) >= 20, f"Expected at least 20 invalid fixtures, found {len(out['invalid'])}"

target = Path(__file__).resolve().parent / 'transfer-vectors.json'
content = json.dumps(out, indent=2) + '\n'
if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true', help='verify the committed fixture instead of rewriting it')
    args = parser.parse_args()
    if args.check:
        if target.read_text() != content:
            raise SystemExit('Transfer fixtures differ; regenerate them and review the diff.')
        print(f'Transfer fixtures match: {len(out["valid"])} valid and {len(out["invalid"])} invalid.')
    else:
        target.write_text(content)
        print(f'Wrote {len(out["valid"])} valid and {len(out["invalid"])} invalid transfer test vectors.')
