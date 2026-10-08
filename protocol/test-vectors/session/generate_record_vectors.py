#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent AES-GCM records from the EDHOC oracle's exporter outputs."""
import json
import struct
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from generate_session_vectors import generate as handshake_vectors


def encode(key, iv, sid, direction, kind, sequence, plaintext):
    nonce = bytes(a ^ b for a, b in zip(iv, bytes(4) + sequence.to_bytes(8, "big")))
    header = struct.pack(">BBQI", 1, kind, sequence, len(plaintext))
    aad = header + sid + bytes([direction])
    return header + AESGCM(key).encrypt(nonce, plaintext, aad), nonce, aad


def generate():
    rows = []
    for index, trace in enumerate(handshake_vectors()["valid"]):
        for direction, kind, sequence, plain in [(1, 1, 0, b""), (2, 2, 0, b""), (1, 3, 1, b"aniCe connection check"), (2, 3, 1, bytes(range(250)) * 16), (1, 4, 2, b""), (2, 3, 2**63, b"high bit"), (1, 3, 2**64 - 1, b"counter boundary")]:
            key = bytes.fromhex(trace[f"export-key-{direction}Hex"])
            iv = bytes.fromhex(trace[f"export-iv-{direction}Hex"])
            sid = bytes.fromhex(trace["export-session-id-0Hex"])
            record, nonce, aad = encode(key, iv, sid, direction, kind, sequence, plain)
            rows.append(dict(name=f"{index}-{direction}-{kind}-{sequence}", keyHex=key.hex(), ivHex=iv.hex(), sessionHex=sid.hex(), direction=direction, kind=kind, sequence=str(sequence), plainHex=plain.hex(), recordHex=record.hex(), nonceHex=nonce.hex(), aadHex=aad.hex()))
    base = rows[2]
    invalid = []
    def add(name, record=None, reason="authentication", **updates):
        row = dict(base)
        row.update(name=name, reason=reason, recordHex=(record if record is not None else bytes.fromhex(base["recordHex"])).hex(), **updates)
        invalid.append(row)
    record = bytes.fromhex(base["recordHex"])
    for i in [2, 9, 14, 18, len(record)-1]:
        changed = bytearray(record);changed[i] ^= 1
        add(f"mutation-{i}", bytes(changed))
    add("bad-version", bytes([2])+record[1:], "malformed")
    add("bad-kind", record[:1]+bytes([99])+record[2:], "malformed")
    add("bad-length", record[:10]+bytes.fromhex("ffffffff")+record[14:], "malformed")
    add("truncated", record[:-1], "malformed")
    add("extra-byte", record+b"\x00", "malformed")
    add("empty", b"", "malformed")
    add("header-only", record[:14], "malformed")
    add("direction-substitution", direction=2)
    add("session-substitution", sessionHex=bytes(32).hex())
    add("key-substitution", keyHex=bytes(32).hex())
    add("iv-substitution", ivHex=bytes(12).hex())
    add("gap", sequence="0")
    add("replay", sequence="2")
    key=bytes.fromhex(base["keyHex"]);iv=bytes.fromhex(base["ivHex"]);sid=bytes.fromhex(base["sessionHex"])
    add("nonempty-control", encode(key,iv,sid,1,1,1,b"bad")[0], "malformed")
    add("oversized", encode(key,iv,sid,1,3,1,bytes(4001))[0], "malformed")
    return dict(fixtureVersion=1,valid=rows,invalid=invalid)


if __name__ == "__main__":
    Path(__file__).with_name("record-vectors.json").write_text(json.dumps(generate(), indent=2)+"\n")
