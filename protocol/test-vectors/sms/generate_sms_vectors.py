#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Independently encodes canonical SMS relay fixtures and malformed boundary messages.
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
    tag = 'aniCe sms'
    request = '01234567-89ab-4cde-8fab-0123456789ab'
    stream = '12345678-9abc-4def-8abc-123456789abc'
    address = '+15551234567'
    thread = '42'
    token = 'addr:+15551234567'
    tie = 1700000000000
    live = 'live:' + hashlib.sha256((address + str(tie) + 'hello').encode('utf8')).hexdigest()[:32]
    hello = hashlib.sha256(b'hello').digest()
    body = b'x' * 24576

    def message(kind, fields):
        return [tag, 1, kind, fields]

    def row(name, value, kind=0):
        return {'name': name, 'kind': value[2] if isinstance(value, list) and len(value) > 2 and isinstance(value[2], int) else kind, 'bytesHex': encode(value).hex()}

    good = [
        row('capability', message(1, [24576, 8, 50, 50])),
        row('thread-request', message(2, [request])),
        row('thread-record-provider', message(3, [request, thread, address, 'See you at 6', tie, 2])),
        row('thread-record-address-token', message(3, [request, token, 'Bank', '', 0, 0])),
        row('thread-record-max-strings', message(3, [request, '1' * 80, 'a' * 64, 's' * 160, 9007199254740991, 9007199254740991])),
    ]
    good += [row('thread-done-' + str(result), message(4, [request, result])) for result in range(7)]
    good += [
        row('history-request-initial', message(5, [request, thread, 0, '', 50])),
        row('history-request-tie', message(5, [request, token, tie, 'sms:100', 1])),
        row('message-begin-live', message(6, [stream, '', live, token, address, tie, 0, True, 5, 1, hello])),
        row('message-begin-history-incoming', message(6, [stream, request, 'sms:100', thread, address, tie, 0, False, 5, 1, hello])),
        row('message-begin-history-outgoing', message(6, [stream, request, 'mms:7', thread, address, tie + 1, 1, False, 5, 1, hello])),
        row('message-begin-max-body', message(6, [stream, '', 'live:' + hashlib.sha256(body).hexdigest()[:32], token, address, 9007199254740991, 0, False, 24576, 8, hashlib.sha256(body).digest()])),
        row('message-fragment', message(7, [stream, 0, b'hello'])),
        row('message-fragment-max', message(7, [stream, 7, b'x' * 3072])),
        row('message-fragment-unicode-nul', message(7, [stream, 0, 'नमस्ते 👋 \ufffd'.encode('utf8')])),
        row('message-commit', message(8, [stream])),
    ]
    good += [row('message-result-' + str(result), message(9, [stream, result])) for result in range(7)]
    good += [
        row('history-done-more', message(10, [request, 0, tie, 'sms:100'])),
        row('history-done-end', message(10, [request, 0, 0, ''])),
        row('history-done-disabled', message(10, [request, 1, 0, ''])),
        row('history-done-failure', message(10, [request, 5, 0, ''])),
        row('send-begin', message(11, [request, thread, address, 5, 1, hello])),
        row('send-begin-max', message(11, [request, token, address, 24576, 8, hashlib.sha256(body).digest()])),
        row('send-fragment', message(12, [request, 0, b'hello'])),
        row('send-fragment-max', message(12, [request, 7, b'y' * 3072])),
        row('send-commit', message(13, [request])),
        row('send-result-unknown-id', message(14, [request, 0, '', 0])),
        row('send-result-provider-id', message(14, [request, 0, 'sms:777', tie])),
        row('send-result-failed', message(14, [request, 5, '', 0])),
    ]
    for index, message_id in enumerate(['sms:99', 'sms:100', 'sms:101']):
        good.append(row('history-tie-' + str(index), message(6, [stream, request, message_id, thread, address, tie, 0, False, 5, 1, hello])))
    good.append(row('history-done-tie-cursor', message(10, [request, 0, tie, 'sms:99'])))

    bad = [
        row('wrong-tag', ['aniCe sms2', 1, 1, [24576, 8, 50, 50]]),
        row('version-0', [tag, 0, 1, [24576, 8, 50, 50]]),
        row('version-2', [tag, 2, 1, [24576, 8, 50, 50]]),
        row('kind-0', message(0, [])),
        row('kind-15', message(15, [])),
        row('missing-fields', [tag, 1, 1]),
        row('extra-envelope', [tag, 1, 1, [24576, 8, 50, 50], 0]),
        row('kind-type', [tag, 1, '1', [24576, 8, 50, 50]]),
        row('fields-type', [tag, 1, 1, 24576]),
        row('capability-body-low', message(1, [24575, 8, 50, 50])),
        row('capability-fragments', message(1, [24576, 7, 50, 50])),
        row('capability-threads', message(1, [24576, 8, 49, 50])),
        row('capability-messages', message(1, [24576, 8, 50, 49])),
        row('capability-short', message(1, [24576, 8, 50])),
        row('capability-extra', message(1, [24576, 8, 50, 50, 0])),
        row('thread-request-uppercase', message(2, [request.upper()])),
        row('thread-request-no-hyphens', message(2, [request.replace('-', '')])),
        row('thread-request-bad-char', message(2, [request[:-1] + 'g'])),
        row('thread-request-empty', message(2, [''])),
        row('thread-record-empty-thread', message(3, [request, '', address, 's', 0, 0])),
        row('thread-record-long-thread', message(3, [request, 'a' * 81, address, 's', 0, 0])),
        row('thread-record-empty-address', message(3, [request, thread, '', 's', 0, 0])),
        row('thread-record-long-address', message(3, [request, thread, 'a' * 65, 's', 0, 0])),
        row('thread-record-long-snippet', message(3, [request, thread, address, 's' * 161, 0, 0])),
        row('thread-record-negative-date', message(3, [request, thread, address, 's', -1, 0])),
        row('thread-record-date-overflow', message(3, [request, thread, address, 's', 2**53, 0])),
        row('thread-record-unread-overflow', message(3, [request, thread, address, 's', 0, 2**53])),
        row('thread-done-result-7', message(4, [request, 7])),
        row('thread-done-result-negative', message(4, [request, -1])),
        row('history-request-limit-0', message(5, [request, thread, 0, '', 0])),
        row('history-request-limit-51', message(5, [request, thread, 0, '', 51])),
        row('history-request-cursor-overflow', message(5, [request, thread, 2**53, '', 50])),
        row('history-request-bad-cursor-id', message(5, [request, thread, 0, 'bogus', 50])),
        row('history-request-short-cursor-id', message(5, [request, thread, 0, 'live:' + 'a' * 31, 50])),
        row('message-begin-direction', message(6, [stream, '', live, token, address, 0, 2, False, 5, 1, hello])),
        row('message-begin-unread-type', message(6, [stream, '', live, token, address, 0, 0, 1, 5, 1, hello])),
        row('message-begin-empty-body', message(6, [stream, '', live, token, address, 0, 0, False, 0, 1, hello])),
        row('message-begin-body-overflow', message(6, [stream, '', live, token, address, 0, 0, False, 24577, 9, hello])),
        row('message-begin-fragments-9', message(6, [stream, '', live, token, address, 0, 0, False, 24576, 9, hello])),
        row('message-begin-digest-short', message(6, [stream, '', live, token, address, 0, 0, False, 5, 1, hello[:-1]])),
        row('message-begin-digest-long', message(6, [stream, '', live, token, address, 0, 0, False, 5, 1, hello + b'\x00'])),
        row('message-begin-fragment-math', message(6, [stream, '', live, token, address, 0, 0, False, 3073, 1, hello])),
        row('message-begin-fragment-math-high', message(6, [stream, '', live, token, address, 0, 0, False, 24576, 7, hello])),
        row('message-begin-bad-request', message(6, [stream, 'not-uuid', live, token, address, 0, 0, False, 5, 1, hello])),
        row('message-begin-bad-message-id', message(6, [stream, '', 'bogus', token, address, 0, 0, False, 5, 1, hello])),
        row('message-begin-sms-empty-id', message(6, [stream, '', 'sms:', token, address, 0, 0, False, 5, 1, hello])),
        row('message-begin-live-uppercase', message(6, [stream, '', 'live:' + hashlib.sha256(b'x').hexdigest()[:32].upper(), token, address, 0, 0, False, 5, 1, hello])),
        row('message-fragment-index-8', message(7, [stream, 8, b'hello'])),
        row('message-fragment-index-negative', message(7, [stream, -1, b'hello'])),
        row('message-fragment-empty-bytes', message(7, [stream, 0, b''])),
        row('message-fragment-bytes-overflow', message(7, [stream, 0, b'x' * 3073])),
        row('message-commit-empty-stream', message(8, [''])),
        row('message-result-7', message(9, [stream, 7])),
        row('message-result-negative', message(9, [stream, -1])),
        row('history-done-result-7', message(10, [request, 7, 0, ''])),
        row('history-done-bad-cursor-id', message(10, [request, 0, 0, 'bogus'])),
        row('history-done-cursor-overflow', message(10, [request, 0, 2**53, ''])),
        row('send-begin-body-overflow', message(11, [request, thread, address, 24577, 9, hello])),
        row('send-begin-fragments-9', message(11, [request, thread, address, 24576, 9, hello])),
        row('send-begin-digest-short', message(11, [request, thread, address, 5, 1, hello[:-1]])),
        row('send-fragment-index-8', message(12, [request, 8, b'hello'])),
        row('send-fragment-index-negative', message(12, [request, -1, b'hello'])),
        row('send-fragment-empty-bytes', message(12, [request, 0, b''])),
        row('send-fragment-bytes-overflow', message(12, [request, 0, b'y' * 3073])),
        row('send-result-7', message(14, [request, 7, '', 0])),
        row('send-result-failed-with-id', message(14, [request, 5, 'sms:10', 0])),
        row('send-result-bad-message-id', message(14, [request, 0, 'bogus', 0])),
        row('send-result-negative-date', message(14, [request, 0, '', -1])),
    ]
    done = encode(message(4, [request, 0]))
    record = bytearray(encode(message(3, [request, thread, 'Bank', 'ok', 0, 0])))
    record[record.index(b'Bank')] = 0xff
    bad += [
        {'name': 'truncated', 'kind': 4, 'bytesHex': done[:-1].hex()},
        {'name': 'trailing', 'kind': 4, 'bytesHex': (done + b'\x00').hex()},
        {'name': 'nonminimal-result', 'kind': 4, 'bytesHex': (done[:-1] + b'\x18\x00').hex()},
        {'name': 'indefinite-array', 'kind': 4, 'bytesHex': (b'\x9f' + done[1:] + b'\xff').hex()},
        {'name': 'invalid-utf8', 'kind': 3, 'bytesHex': bytes(record).hex()},
    ]
    assert len(good) >= 42 and len(bad) >= 70
    return {'valid': good, 'invalid': bad}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true', help='verify the committed fixture instead of rewriting it')
    args = parser.parse_args()
    target = Path(__file__).with_name('sms-vectors.json')
    content = json.dumps(generate(), indent=2) + '\n'
    if args.check:
        if target.read_text() != content:
            raise SystemExit('SMS fixtures differ; regenerate them and review the diff.')
        print('SMS fixtures match their independent encoder.')
    else:
        target.write_text(content)
