#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Generates independent canonical CBOR fixtures and rejects malformed private-listening shapes and timelines.
import argparse
import copy
import io
import json
import re
import struct
from pathlib import Path

import cbor2

TAG = "aniCe private listening"
STREAM_ID = "01234567-89ab-4cde-8fab-0123456789ab"
MAX_INTEGER = 2**63 - 1
FRAMES = 960
PCM_BYTES = 3840
MAX_SEQUENCE = MAX_INTEGER // FRAMES
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")


def encode(value):
    return cbor2.dumps(value, canonical=True)


def parse(raw):
    if len(raw) > 524416:
        raise ValueError("malformed")
    try:
        source = io.BytesIO(raw)
        row = cbor2.CBORDecoder(source).decode()
    except (cbor2.CBORDecodeError, EOFError) as error:
        raise ValueError("malformed") from error
    if source.tell() != len(raw) or encode(row) != raw:
        raise ValueError("malformed")
    if type(row) is not list or not row or row[0] != TAG:
        return None
    if (len(raw) > 4000 or len(row) != 4 or type(row[1]) is not int or row[1] != 1 or
            type(row[2]) is not int or row[2] not in range(6) or type(row[3]) is not list):
        raise ValueError("malformed")
    kind, fields = row[2], row[3]
    arities = (5, 5, 2, 4, 2, 7)
    if len(fields) != arities[kind]:
        raise ValueError("malformed")

    def integer(index, minimum=0, maximum=MAX_INTEGER):
        return type(fields[index]) is int and minimum <= fields[index] <= maximum

    def uuid():
        return type(fields[0]) is str and UUID.fullmatch(fields[0]) is not None

    def audio_format(index):
        return all(type(fields[index + i]) is int and fields[index + i] == value
                   for i, value in enumerate((48000, 2, 16, FRAMES)))

    if kind == 0:
        valid = audio_format(0) and type(fields[4]) is bool
    elif kind == 1:
        valid = uuid() and audio_format(1)
    elif kind == 2:
        valid = uuid() and integer(1, 0, 9)
    elif kind == 3:
        valid = (uuid() and integer(1, 1, MAX_SEQUENCE) and integer(2) and
                 fields[2] == (fields[1] - 1) * FRAMES and
                 type(fields[3]) is bytes and len(fields[3]) == PCM_BYTES)
    elif kind == 4:
        valid = uuid() and integer(1, 0, 7)
    else:
        valid = (uuid() and integer(1, 0, 1) and integer(2, 0, 5) and integer(3, 0, MAX_SEQUENCE) and
                 integer(4) and integer(5, 0, 48000) and integer(6, 0, 2**32 - 1) and
                 (fields[1] != 0 or fields[6] == 0))
    if not valid:
        raise ValueError("malformed")
    return row


def vectors():
    pcm = b"".join(struct.pack("<hh", left, right)
                   for left, right in ((0, 0), (32767, -32768), (-1, 1), (12345, -12345)) * 240)
    capability = [TAG, 1, 0, [48000, 2, 16, FRAMES, True]]
    start = [TAG, 1, 1, [STREAM_ID, 48000, 2, 16, FRAMES]]
    audio = [TAG, 1, 3, [STREAM_ID, 1, 0, pcm]]
    status = [TAG, 1, 5, [STREAM_ID, 1, 2, 1, FRAMES, FRAMES, 0]]
    valid = [
        ("capability-enabled", capability),
        ("capability-disabled", [TAG, 1, 0, [48000, 2, 16, FRAMES, False]]),
        ("start", start),
        ("audio-pcm16-stereo", audio),
        ("audio-silence", [TAG, 1, 3, [STREAM_ID, 1, 0, bytes(PCM_BYTES)]]),
        ("audio-gap", [TAG, 1, 3, [STREAM_ID, 201, 200 * FRAMES, pcm]]),
        ("audio-maximum-timeline", [TAG, 1, 3,
                                   [STREAM_ID, MAX_SEQUENCE, (MAX_SEQUENCE - 1) * FRAMES, pcm]]),
        ("status-mac-preparing", [TAG, 1, 5, [STREAM_ID, 0, 1, 0, 0, 0, 0]]),
        ("status-maximum-counters", [TAG, 1, 5,
                                     [STREAM_ID, 1, 2, MAX_SEQUENCE, MAX_INTEGER, 48000, 2**32 - 1]]),
    ]
    valid += [("result-" + str(code), [TAG, 1, 2, [STREAM_ID, code]]) for code in range(10)]
    valid += [("stop-" + str(code), [TAG, 1, 4, [STREAM_ID, code]]) for code in range(8)]
    valid += [("status-state-" + str(state), [TAG, 1, 5,
                                             [STREAM_ID, 1, state, 1, FRAMES, FRAMES, 0]])
              for state in range(6)]
    valid += [("uuid-variant-" + variant, [TAG, 1, 1,
                                          [STREAM_ID[:19] + variant + STREAM_ID[20:], 48000, 2, 16, FRAMES]])
              for variant in "89ab"]
    # Exercise every CBOR integer-width transition on a real packet timeline.
    valid += [("audio-sequence-" + str(sequence), [TAG, 1, 3,
                                                  [STREAM_ID, sequence, (sequence - 1) * FRAMES, pcm]])
              for sequence in (23, 24, 255, 256, 65535, 65536, 2**32 - 1, 2**32)]

    bad = []

    def reject(name, row):
        bad.append((name, encode(row)))

    reject("unknown-version", [TAG, 2, 0, capability[3]])
    reject("boolean-version", [TAG, True, 0, capability[3]])
    reject("unknown-kind", [TAG, 1, 6, []])
    reject("negative-kind", [TAG, 1, -1, []])
    reject("boolean-kind", [TAG, 1, True, start[3]])
    reject("missing-envelope-field", start[:-1])
    reject("extra-envelope-field", start + [0])
    reject("non-array-fields", [TAG, 1, 1, {}])

    seeds = (capability, start, [TAG, 1, 2, [STREAM_ID, 0]], audio,
             [TAG, 1, 4, [STREAM_ID, 0]], status)
    for kind, seed in enumerate(seeds):
        reject(f"kind-{kind}-missing-field", seed[:3] + [seed[3][:-1]])
        reject(f"kind-{kind}-extra-field", seed[:3] + [seed[3] + [0]])
        for other_kind in range(6):
            if other_kind == kind or {kind, other_kind} == {2, 4}:
                continue  # Result and Stop intentionally share their [UUID, code] shape.
            reject(f"kind-{kind}-payload-{other_kind}", seed[:3] + [seeds[other_kind][3]])

    for kind in range(1, 6):
        for name, invalid_id in (
            ("uppercase", STREAM_ID.upper()), ("short", "bad"),
            ("uuid-v1", STREAM_ID[:14] + "1" + STREAM_ID[15:]),
            ("variant", STREAM_ID[:19] + "7" + STREAM_ID[20:]),
            ("suffix", STREAM_ID + "\n"), ("unicode", "é" + STREAM_ID[1:]),
            ("wrong-type", bytes(36)),
        ):
            row = copy.deepcopy(seeds[kind])
            row[3][0] = invalid_id
            reject(f"kind-{kind}-uuid-{name}", row)

    for kind, base in ((0, 0), (1, 1)):
        for index, value in enumerate((44100, 1, 32, 480)):
            row = copy.deepcopy(seeds[kind])
            row[3][base + index] = value
            reject(f"kind-{kind}-format-{index}", row)
        row = copy.deepcopy(seeds[kind])
        row[3][base + 1] = True
        reject(f"kind-{kind}-boolean-channels", row)
    for value in (0, 1, "true", None):
        reject(f"consent-not-bool-{value}", capability[:3] + [capability[3][:-1] + [value]])
    for code in (-1, 10):
        reject(f"result-out-of-range-{code}", [TAG, 1, 2, [STREAM_ID, code]])
    for code in (-1, 8):
        reject(f"stop-out-of-range-{code}", [TAG, 1, 4, [STREAM_ID, code]])

    for name, sequence, offset in (
        ("zero-sequence", 0, 0), ("negative-sequence", -1, 0),
        ("first-offset-not-zero", 1, FRAMES), ("offset-mismatch", 2, FRAMES + 1),
        ("negative-offset", 1, -1), ("boolean-sequence", True, 0),
        ("boolean-offset", 1, False), ("sequence-product-overflow", MAX_INTEGER, 0),
        ("packet-end-overflow", MAX_SEQUENCE + 1, MAX_SEQUENCE * FRAMES),
        ("offset-uint64", 1, 2**63), ("sequence-uint64", 2**63, 0),
    ):
        reject(name, [TAG, 1, 3, [STREAM_ID, sequence, offset, pcm]])
    for size in (0, PCM_BYTES - 1, PCM_BYTES + 1, 4000):
        reject(f"pcm-size-{size}", [TAG, 1, 3, [STREAM_ID, 1, 0, bytes(size)]])
    reject("pcm-not-bytes", [TAG, 1, 3, [STREAM_ID, 1, 0, "x" * PCM_BYTES]])

    for index, values in ((1, (-1, 2, True)), (2, (-1, 6, True)),
                          (3, (-1, MAX_SEQUENCE + 1, True)),
                          (4, (-1, 2**63, True)), (5, (-1, 48001, True)),
                          (6, (-1, 2**32, True))):
        for value in values:
            row = copy.deepcopy(status)
            row[3][index] = value
            reject(f"status-field-{index}-{value}", row)
    reject("mac-claims-native-underruns", [TAG, 1, 5, [STREAM_ID, 0, 2, 1, FRAMES, 0, 1]])

    raw = encode(start)
    prefix = b"\x84" + encode(TAG)
    bad += [
        ("empty", b""),
        ("truncated", raw[:-1]),
        ("trailing", raw + b"\x00"),
        ("indefinite-envelope", b"\x9f" + raw[1:] + b"\xff"),
        ("nonminimal-version", prefix + b"\x18" + raw[len(prefix):]),
        ("float-version", prefix + b"\xf9\x3c\x00" + raw[len(prefix) + 1:]),
        ("tagged-envelope", b"\xc0" + raw),
    ]
    pcm_offset = len(encode(audio)) - len(pcm) - 3
    encoded_audio = encode(audio)
    bad += [
        ("nonminimal-pcm-length", encoded_audio[:pcm_offset] + b"\x5a\x00\x00\x0f\x00" + pcm),
        ("truncated-pcm", encoded_audio[:-1]),
    ]

    positives = []
    for name, row in valid:
        raw = encode(row)
        assert parse(raw) == row, name
        positives.append(dict(name=name, kind=row[2], bytesHex=raw.hex()))
    negatives = []
    for name, raw in bad:
        try:
            parse(raw)
        except ValueError:
            negatives.append(dict(name=name, bytesHex=raw.hex()))
        else:
            raise AssertionError("Negative fixture accepted: " + name)
    unknown = [
        ("other-tag", ["another feature", 1, 3, []]),
        ("large-other-feature", ["aniCe transfer", 1, 5, [bytes(8192)]]),
        ("non-array-data", b"aniCe connection check"),
    ]
    unrecognized = []
    for name, row in unknown:
        raw = encode(row)
        assert parse(raw) is None
        unrecognized.append(dict(name=name, bytesHex=raw.hex()))
    assert len(encode(valid[6][1])) == 3927
    assert len(positives) >= 40 and len(negatives) >= 100
    assert len({row["name"] for row in positives + negatives + unrecognized}) == (
        len(positives) + len(negatives) + len(unrecognized))
    return dict(valid=positives, invalid=negatives, unrecognized=unrecognized)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rows = vectors()
    target = Path(__file__).with_name("vectors.json")
    content = json.dumps(rows, indent=2) + "\n"
    if args.check:
        if target.read_text(encoding="utf-8") != content:
            raise SystemExit("Private Listening fixtures differ; regenerate them and review the diff.")
    else:
        target.write_text(content, encoding="utf-8")
    print(f"Private Listening: {len(rows['valid'])} valid / {len(rows['invalid'])} invalid")
