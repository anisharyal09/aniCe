#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# /// script
# dependencies = ["cryptography==50.0.1"]
# ///
"""Independent method-3 commitment, ECDH, digits and channel vectors; use --check for drift."""

import argparse
import base64
import hashlib
import hmac
import json
from pathlib import Path
import struct

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


def fields(*values):
    return b"".join(struct.pack(">I", len(v)) + v for v in values)


def digest(value):
    return hashlib.sha256(value).digest()


def hkdf(key, salt, info):
    return HKDF(hashes.SHA256(), 32, salt, info).derive(key)


def public(key):
    return key.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def identity(scalar, platform):
    point = public(ec.derive_private_key(scalar, ec.SECP256R1()))
    return json.dumps({
        "identitySchemaVersion": 1,
        "deviceId": "01234567-89ab-4cde-8fab-" + f"{scalar:012x}",
        "deviceName": "Synthetic " + platform,
        "platform": platform,
        "algorithm": "P-256",
        "publicKey": base64.b64encode(point).decode(),
        "fingerprint": digest(point).hex(),
    }, separators=(",", ":"), sort_keys=True).encode()


def vector(seed):
    client = ec.derive_private_key(1, ec.SECP256R1())
    server = ec.derive_private_key(2, ec.SECP256R1())
    cp, sp = public(client), public(server)
    rendezvous, sn = bytes(range(16)), bytes(range(32))
    cn = digest(b"synthetic comparison nonce" + struct.pack(">I", seed))
    scn = bytes(range(32, 64))
    cs, ss = bytes(range(64, 96)), bytes(range(96, 128))
    ci, si = identity(3, "android"), identity(4, "macos")
    ic = digest(fields(b"aniCe sas identity v1", b"\x01", cs, ci))
    isc = digest(fields(b"aniCe sas identity v1", b"\x02", ss, si))
    cc = digest(fields(b"aniCe sas commitment v1", b"\x03", rendezvous, sn, b"\x01", cp, cn, ic))
    sc = digest(fields(b"aniCe sas commitment v1", b"\x03", rendezvous, sn, b"\x02", sp, scn, isc))
    transcript = fields(b"aniCe pairing sas v1", b"\x03", rendezvous, sn, cc, sc,
                        cp, sp, cn, scn, ic, isc)
    th = digest(transcript)
    shared = client.exchange(ec.ECDH(), server.public_key())
    key = hkdf(shared, th, fields(b"aniCe sas bootstrap v1", th))
    derive = lambda label: hkdf(key, th, b"aniCe pairing v1 " + label)
    counter = 0
    while True:
        raw = hmac.digest(derive(b"sas-digits"),
                          fields(b"aniCe sas digits v1", th, struct.pack(">I", counter)), "sha256")
        n = int.from_bytes(raw[:4], "big")
        if n < 4_294_000_000:
            digits = f"{n % 1_000_000:06d}"
            break
        counter += 1
    comparison = AESGCM(derive(b"client-to-server")).encrypt(
        bytes(12), b"\x0f", fields(b"aniCe pairing encrypted v1", th, b"\x01", bytes(8)))
    values = dict(
        rendezvous=rendezvous, serverNonce=sn, clientNonce=cn, serverComparisonNonce=scn,
        clientPublic=cp, serverPublic=sp, clientIdentitySalt=cs, serverIdentitySalt=ss,
        clientIdentity=ci, serverIdentity=si, clientIdentityCommitment=ic,
        serverIdentityCommitment=isc, clientCommitment=cc, serverCommitment=sc,
        transcript=transcript, transcriptHash=th, sharedSecret=shared, bootstrapKey=key,
        clientFinish=hmac.digest(derive(b"client-auth"), transcript, "sha256"),
        serverFinish=hmac.digest(derive(b"channel-confirm"), transcript, "sha256"),
        encryptedComparison=b"\x07" + fields(bytes(8), comparison))
    return {"seed": seed, "digits": digits, **{k + "Hex": v.hex() for k, v in values.items()}}


def generate():
    ordinary = vector(0)
    for seed in range(1, 1000):
        leading = vector(seed)
        if leading["digits"].startswith("0"):
            break
    else:
        raise RuntimeError("No synthetic leading-zero fixture")
    ordinary["name"], leading["name"] = "ordinary", "leading-zero"
    return {
        "fixtureVersion": 1,
        "valid": [ordinary, leading],
        "decimal": [
            {"hex": "00000000", "digits": "000000"},
            {"hex": "00000001", "digits": "000001"},
            {"hex": "000f423f", "digits": "999999"},
            {"hex": "fff13d7f", "digits": "999999"},
            {"hex": "fff13d80", "digits": None},
            {"hex": "ffffffff", "digits": None},
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    path = Path(__file__).with_name("sas-vectors.json")
    encoded = json.dumps(generate(), indent=2) + "\n"
    if options.check:
        if not path.exists() or path.read_text() != encoded:
            raise SystemExit("SAS fixture drift")
        print("SAS vectors match")
    else:
        path.write_text(encoded)
        print("Generated synthetic SAS vectors")


if __name__ == "__main__":
    main()
