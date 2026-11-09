#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Independently encodes canonical notification mirroring fixtures.
import hashlib
import json
from pathlib import Path
import struct
import zlib


def encode(value):
    def head(major, n):
        size = 0 if n < 24 else 1 if n < 256 else 2 if n < 65536 else 4 if n < 2**32 else 8
        return bytes([(major << 5) | (n if not size else {1: 24, 2: 25, 4: 26, 8: 27}[size])]) + (n.to_bytes(size, "big") if size else b"")
    if isinstance(value, bool):
        return b"\xf5" if value else b"\xf4"
    if isinstance(value, int):
        return head(0 if value >= 0 else 1, value if value >= 0 else -1 - value)
    if isinstance(value, str):
        data = value.encode("utf8")
        return head(3, len(data)) + data
    if isinstance(value, bytes):
        return head(2, len(value)) + value
    if isinstance(value, list):
        return head(4, len(value)) + b"".join(map(encode, value))
    raise TypeError(value)


def generate():
    tag = "aniCe notifications"
    epoch = "01234567-89ab-4cde-8fab-0123456789ab"
    token = "11234567-89ab-4cde-8fab-0123456789ab"
    request = "21234567-89ab-4cde-8fab-0123456789ab"
    notification_id = hashlib.sha256(b"notification-1").hexdigest()

    def png_icon(width=1, height=1):
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
        header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
        pixel = zlib.compress(b"".join(b"\x00" + bytes(width * 4) for _ in range(height)))
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", pixel) + chunk(b"IEND", b"")

    def message(kind, fields, version=1, message_tag=tag):
        return [message_tag, version, kind, fields]

    def row(name, value):
        return {"name": name, "kind": value[2], "bytesHex": encode(value).hex()}

    actions = [[index, f"Action {index}", "Reply"] for index in range(8)]
    maximum = ["", notification_id, epoch, 9007199254740991, "p" * 255, "a" * 128,
               "t" * 512, "b" * 1024,
               [[index, "A" * 48, "R" * 48] for index in range(8)]]
    good = [
        row("capability", message(1, [8])),
        row("notification", message(2, ["", notification_id, epoch, 1, "com.example.chat", "Chat", "Ari", "Hello", [[0, "Reply", "Message"]]])),
        row("notification-without-actions", message(2, [token, notification_id, epoch, 2, "com.example.mail", "Mail", "", "", []])),
        row("maximum-notification", message(2, maximum)),
        row("removal", message(3, [notification_id, epoch, 3])),
        row("snapshot-begin", message(4, [token, epoch, 3])),
        row("snapshot-end", message(5, [token])),
        row("tap-action", message(6, [request, notification_id, epoch, 1, -1, ""])),
        row("reply-action", message(6, [request, notification_id, epoch, 1, 0, "Hi"])),
        *[row(f"action-result-{result}", message(7, [request, result])) for result in range(4)],
        row("dismiss", message(8, [request, notification_id, epoch, 1])),
        row("source-app-icon", message(9, ["com.example.chat", png_icon()])),
    ]

    invalid = [
        row("wrong-tag", message(1, [8], message_tag="aniCe other")),
        row("wrong-version", message(1, [8], version=2)),
        row("unknown-kind", message(10, [])),
        row("source-icon-bad-signature", message(9, ["com.example.chat", b"not-a-png-image"])),
        row("source-icon-over-limit", message(9, ["com.example.chat", b"\x89PNG\r\n\x1a\n" + b"x" * 3000])),
        row("source-icon-over-dimension-limit", message(9, ["com.example.chat", png_icon(width=129)])),
        row("bad-id", message(3, ["x" * 64, epoch, 1])),
        row("action-index", message(6, [request, notification_id, epoch, 1, 8, ""])),
        row("snapshot-watermark", message(4, [token, epoch, -1])),
        row("empty-package", message(2, ["", notification_id, epoch, 1, "", "Chat", "", "", []])),
        row("bad-snapshot-token", message(2, ["x" * 36, notification_id, epoch, 1, "com.example.chat", "Chat", "", "", []])),
        row("body-over-limit", message(2, ["", notification_id, epoch, 1, "com.example.chat", "Chat", "", "b" * 1025, []])),
        row("duplicate-action-index", message(2, ["", notification_id, epoch, 1, "com.example.chat", "Chat", "", "", [[0, "One", ""], [0, "Two", ""]]])),
        row("empty-action-title", message(2, ["", notification_id, epoch, 1, "com.example.chat", "Chat", "", "", [[0, "", ""]]])),
        row("bad-epoch", message(3, [notification_id, "not-a-uuid", 1])),
        row("zero-sequence", message(3, [notification_id, epoch, 0])),
        row("result-code", message(7, [request, 4])),
        row("uppercase-request", message(6, [request.upper(), notification_id, epoch, 1, 0, "Hi"])),
        row("notification-fields", message(2, ["", notification_id, epoch, 1, "com.example.chat", "Chat"])),
    ]
    capability = encode(message(1, [8]))
    invalid.append({"name": "noncanonical-integer", "kind": 1, "bytesHex": (capability[:-1] + b"\x18\x08").hex()})
    invalid.append({"name": "record-over-limit", "kind": None, "bytesHex": (b"\x00" * 4001).hex()})
    return {"valid": good, "invalid": invalid}


if __name__ == "__main__":
    target = Path(__file__).with_name("notification-vectors.json")
    target.write_text(json.dumps(generate(), indent=2) + "\n")
