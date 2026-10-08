#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent RFC 9528 method-0/suite-5 oracle. All private keys are PUBLIC test material."""
import argparse
import hashlib
import json
from pathlib import Path

import cbor2
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand
from cryptography.hazmat.primitives import hmac


def enc(value):
    return cbor2.dumps(value, canonical=True)


def seq(*values):
    return b"".join(enc(v) for v in values)


def digest(data):
    return hashlib.sha256(data).digest()


def extract(salt, ikm):
    h = hmac.HMAC(salt, hashes.SHA256())
    h.update(ikm)
    return h.finalize()


def kdf(prk, label, context, length):
    return HKDFExpand(algorithm=hashes.SHA256(), length=length,
                      info=seq(label, context, length)).derive(prk)


def pub(key):
    return key.public_key().public_bytes(serialization.Encoding.X962,
                                         serialization.PublicFormat.UncompressedPoint)


def credential(identity):
    point = bytes.fromhex(identity["publicHex"])
    return {2: identity["deviceId"], 8: {1: {1: 2, 3: -7, -1: 1,
                                           -2: point[1:33], -3: point[33:65]}}}


def make_identity(scalar, device_id, platform):
    key = ec.derive_private_key(scalar, ec.SECP256R1())
    point = pub(key)
    return key, {"deviceId": device_id, "platform": platform, "publicHex": point.hex(),
                 "fingerprintHex": digest(point).hex(), "privateHex": scalar.to_bytes(32, "big").hex()}


def signing_input(identity, transcript_hash, mac):
    kid = bytes.fromhex(identity["fingerprintHex"])
    return enc(["Signature1", enc({4: kid}), seq(transcript_hash, credential(identity)), mac])


def sign(key, data):
    der = key.sign(data, ec.ECDSA(hashes.SHA256(), deterministic_signing=True))
    r, s = decode_dss_signature(der)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def aad(th):
    return enc(["Encrypt0", b"", th])


def trace(index):
    i_key, initiator = make_identity(100 + index, f"00000000-0000-4000-8000-{index:012d}", "android")
    r_key, responder = make_identity(200 + index, f"00000000-0000-4000-9000-{index:012d}", "macos")
    x = ec.derive_private_key(10 + index, ec.SECP256R1())
    y = ec.derive_private_key(20 + index, ec.SECP256R1())
    gx, gy = pub(x)[1:33], pub(y)[1:33]
    ci, cr = bytes([index]) * 8, bytes([index + 10]) * 8
    m1 = seq(0, 5, gx, ci)
    th2 = digest(seq(gy, digest(m1)))
    z = x.exchange(ec.ECDH(), y.public_key())
    prk = extract(th2, z)  # In method 0 all three handshake PRKs are equal.
    kid_i, kid_r = bytes.fromhex(initiator["fingerprintHex"]), bytes.fromhex(responder["fingerprintHex"])
    context2 = seq(cr, {4: kid_r}, th2, credential(responder))
    mac2 = kdf(prk, 2, context2, 32)
    input2 = signing_input(responder, th2, mac2)
    sig2 = sign(r_key, input2)
    p2 = seq(cr, kid_r, sig2)
    stream2 = kdf(prk, 0, th2, len(p2))
    m2 = enc(gy + bytes(a ^ b for a, b in zip(p2, stream2)))
    th3 = digest(enc(th2) + p2 + enc(credential(responder)))
    context3 = seq({4: kid_i}, th3, credential(initiator))
    mac3 = kdf(prk, 6, context3, 32)
    input3 = signing_input(initiator, th3, mac3)
    sig3 = sign(i_key, input3)
    p3 = seq(kid_i, sig3)
    k3, iv3 = kdf(prk, 3, th3, 32), kdf(prk, 4, th3, 12)
    m3 = enc(ChaCha20Poly1305(k3).encrypt(iv3, p3, aad(th3)))
    th4 = digest(enc(th3) + p3 + enc(credential(initiator)))
    k4, iv4 = kdf(prk, 8, th4, 32), kdf(prk, 9, th4, 12)
    m4 = enc(ChaCha20Poly1305(k4).encrypt(iv4, b"", aad(th4)))
    out = kdf(prk, 7, th4, 32)
    exporter = kdf(out, 10, b"", 32)
    values = dict(gx=gx, gy=gy, xPublic=pub(x), yPublic=pub(y), ci=ci, cr=cr, sharedSecret=z, credentialI=enc(credential(initiator)),
                  credentialR=enc(credential(responder)), message1=m1, message2=m2, message3=m3,
                  message4=m4, th2=th2, th3=th3, th4=th4, prk2e=prk, prk3e2m=prk, prk4e3m=prk,
                  context2=context2, context3=context3, mac2=mac2, mac3=mac3, signature2=sig2,
                  signature3=sig3, signingInput2=input2, signingInput3=input3, plaintext2=p2,
                  plaintext3=p3, keystream2=stream2, k3=k3, iv3=iv3, k4=k4, iv4=iv4,
                  aad3=aad(th3), aad4=aad(th4), prkOut=out, prkExporter=exporter)
    # Application exporter profile; no record-channel implementation is enabled by these vectors.
    for purpose, direction, size in [("key", 1, 32), ("key", 2, 32), ("iv", 1, 12),
                                      ("iv", 2, 12), ("session-id", 0, 32)]:
        context = enc(["aniCe session", 1, enc(credential(initiator)),
                       enc(credential(responder)), direction, purpose])
        values[f"exportContext-{purpose}-{direction}"] = context
        values[f"export-{purpose}-{direction}"] = kdf(exporter, 32768, context, size)
    return {"name": f"suite5-{index}", "initiator": initiator, "responder": responder,
            "xHex": (10 + index).to_bytes(32, "big").hex(),
            "yHex": (20 + index).to_bytes(32, "big").hex(),
            **{k + "Hex": v.hex() for k, v in values.items()}}


def invalid(v):
    m1, m2, m3, m4 = [bytes.fromhex(v[f"message{i}Hex"]) for i in range(1, 5)]
    gx, ci = bytes.fromhex(v["gxHex"]), bytes.fromhex(v["ciHex"])
    rows = []
    def add(name, stage, wire, reason):
        rows.append(dict(name=name, stage=stage, wireHex=wire.hex(), reason=reason))
    add("wrong-method", 1, seq(3, 5, gx, ci), "unsupportedProfile")
    add("wrong-suite", 1, seq(0, 2, gx, ci), "unsupportedProfile")
    add("suite-list", 1, seq(0, [5, 2], gx, ci), "unsupportedProfile")
    add("nonminimal-method", 1, b"\x18\x00" + m1[1:], "malformed")
    add("trailing-ead", 1, m1 + enc(0), "malformed")
    add("truncated", 1, m1[:-1], "malformed")
    add("invalid-point", 1, seq(0, 5, b"\xff" * 32, ci), "malformed")
    add("short-point", 1, seq(0, 5, gx[:-1], ci), "malformed")
    add("empty-connection-id", 1, seq(0, 5, gx, b""), "malformed")
    add("overlong-connection-id", 1, seq(0, 5, gx, b"a" * 9), "malformed")
    add("truncated-response", 2, enc(bytes(32)), "malformed")
    add("response-invalid-point", 2, enc(b"\xff" * 32 + cbor2.loads(m2)[32:]), "malformed")
    p2 = bytes.fromhex(v["plaintext2Hex"])
    keystream = bytes.fromhex(v["keystream2Hex"])
    def response(p):
        return enc(bytes.fromhex(v["gyHex"]) + bytes(a ^ b for a, b in zip(p, keystream)))
    altered = bytearray(p2); altered[-1] ^= 1
    add("altered-responder-signature", 2, response(altered), "authentication")
    unknown = seq(bytes.fromhex(v["crHex"]), bytes(32), bytes.fromhex(v["signature2Hex"]))
    add("unknown-responder", 2, response(unknown), "untrustedPeer")
    add("response-trailing-data", 2, m2 + enc(False), "malformed")
    corrupted = bytearray(cbor2.loads(m3)); corrupted[-1] ^= 1
    add("message3-tag", 3, enc(corrupted), "authentication")
    p3 = bytearray(bytes.fromhex(v["plaintext3Hex"])); p3[-1] ^= 1
    forged3 = ChaCha20Poly1305(bytes.fromhex(v["k3Hex"])).encrypt(
        bytes.fromhex(v["iv3Hex"]), bytes(p3), bytes.fromhex(v["aad3Hex"]))
    add("altered-initiator-signature", 3, enc(forged3), "authentication")
    unknown3 = seq(bytes(32), bytes.fromhex(v["signature3Hex"]))
    add("unknown-initiator", 3, enc(ChaCha20Poly1305(bytes.fromhex(v["k3Hex"])).encrypt(
        bytes.fromhex(v["iv3Hex"]), unknown3, bytes.fromhex(v["aad3Hex"]))), "untrustedPeer")
    corrupted = bytearray(cbor2.loads(m4)); corrupted[-1] ^= 1
    add("message4-tag", 4, enc(corrupted), "authentication")
    add("message4-ead", 4, enc(ChaCha20Poly1305(bytes.fromhex(v["k4Hex"])).encrypt(
        bytes.fromhex(v["iv4Hex"]), enc(0), bytes.fromhex(v["aad4Hex"]))), "malformed")
    add("message4-trailing-data", 4, m4 + enc(True), "malformed")
    return rows


def generate():
    valid = [trace(i) for i in range(1, 4)]
    return {"fixtureVersion": 1, "method": 0, "suite": 5, "valid": valid, "invalid": invalid(valid[0])}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    path = Path(__file__).with_name("session-vectors.json")
    text = json.dumps(generate(), indent=2) + "\n"
    if args.check:
        if not path.exists() or path.read_text() != text:
            raise SystemExit("Session vectors differ from independent regeneration")
        print("Session vectors match independent regeneration")
    else:
        path.write_text(text)
