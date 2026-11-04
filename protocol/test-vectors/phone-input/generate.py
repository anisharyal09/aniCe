# SPDX-License-Identifier: GPL-3.0-or-later
# Independently encodes canonical and adversarial Phone-to-Mac input fixtures.
import argparse
import json
from pathlib import Path


def encode(value):
    def head(major, n):
        if n < 24:
            return bytes([(major << 5) | n])
        size = 1 if n < 256 else 2 if n < 65536 else 4 if n < 2**32 else 8
        return bytes([(major << 5) | {1: 24, 2: 25, 4: 26, 8: 27}[size]]) + n.to_bytes(size, "big")

    if isinstance(value, bool):
        return b"\xf5" if value else b"\xf4"
    if isinstance(value, int):
        return head(0 if value >= 0 else 1, value if value >= 0 else -1 - value)
    if isinstance(value, str):
        data = value.encode("utf-8")
        return head(3, len(data)) + data
    if isinstance(value, list):
        return head(4, len(value)) + b"".join(map(encode, value))
    raise TypeError(value)


def generate():
    tag = "aniCe phone input"
    session = "01234567-89ab-4cde-8fab-0123456789ab"

    def row(name, value):
        return {"name": name, "kind": value[2], "bytesHex": encode(value).hex()}

    valid_values = [
        ("capability", [tag, 1, 1, [1024, 7]]),
        ("start", [tag, 1, 2, [session]]),
        ("accepted", [tag, 1, 3, [session, 0]]),
        ("busy", [tag, 1, 3, [session, 1]]),
        ("text-unicode", [tag, 1, 4, [session, 1, "café — नमस्ते 👩🏽‍💻"]]),
        ("key-down-shift-e", [tag, 1, 5, [session, 2, 8, 2, True]]),
        ("key-up-shift-e", [tag, 1, 5, [session, 3, 8, 0, False]]),
        ("pointer-negative", [tag, 1, 6, [session, 4, -32767, 32767]]),
        ("command-click", [tag, 1, 7, [session, 5, 1, 8]]),
        ("scroll-both-axes", [tag, 1, 8, [session, 6, -12, 31]]),
        ("release-all", [tag, 1, 9, [session, 7]]),
        ("stop", [tag, 1, 10, [session, 8]]),
        ("session-ended-local-stop", [tag, 1, 11, [session, 0]]),
    ]
    bad_values = [
        [tag, 2, 1, [1024, 7]],
        [tag, 1, 0, []],
        [tag, 1, 11, []],
        [tag, 1, 1, [0, 7]],
        [tag, 1, 1, [1025, 7]],
        [tag, 1, 1, [1024, 8]],
        [tag, 1, 2, ["bad"]],
        [tag, 1, 3, [session, 4]],
        [tag, 1, 3, [session, -1]],
        [tag, 1, 4, [session, 0, "x"]],
        [tag, 1, 4, [session, 1, ""]],
        [tag, 1, 4, [session, 1, "🙂" * 257]],
        [tag, 1, 4, [session, 1, 1]],
        [tag, 1, 5, [session, 1, 3, 0, True]],
        [tag, 1, 5, [session, 1, 232, 0, True]],
        [tag, 1, 5, [session, 1, 4, 256, True]],
        [tag, 1, 5, [session, 1, 4, 0, 1]],
        [tag, 1, 6, [session, 1, -32768, 0]],
        [tag, 1, 6, [session, 1, 0, 32768]],
        [tag, 1, 7, [session, 1, 8, 0]],
        [tag, 1, 7, [session, 1, 0, -1]],
        [tag, 1, 8, [session, 1, 0]],
        [tag, 1, 9, [session]],
        [tag, 1, 10, [session, 1, 0]],
        [tag, 1, 10, [session.upper(), 1]],
        [tag, 1, 11, [session, 4]],
        [tag, 1, 11, ["bad", 0]],
        [tag, 1, 4, [session, 1, "x"], 0],
    ]
    invalid = [row("invalid-" + str(i), value) for i, value in enumerate(bad_values)]
    message = [tag, 1, 4, [session, 1, "x"]]
    encoded = encode(message)
    version_offset = 1 + len(encode(tag))
    nonminimal = encoded[:version_offset] + b"\x18\x01" + encoded[version_offset + 1:]
    invalid += [
        {"name": "truncated", "bytesHex": encoded[:-1].hex()},
        {"name": "trailing", "bytesHex": (encoded + b"\x00").hex()},
        {"name": "nonminimal-version", "bytesHex": nonminimal.hex()},
    ]
    return {"valid": [row(*value) for value in valid_values], "invalid": invalid}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify the fixture instead of rewriting it")
    args = parser.parse_args()
    target = Path(__file__).with_name("phone-input-vectors.json")
    content = json.dumps(generate(), indent=2, ensure_ascii=False) + "\n"
    if args.check:
        if target.read_text() != content:
            raise SystemExit("Phone-to-Mac input fixtures differ; regenerate them and review the diff.")
        print("Phone-to-Mac input fixtures match their independent encoder.")
    else:
        target.write_text(content)
