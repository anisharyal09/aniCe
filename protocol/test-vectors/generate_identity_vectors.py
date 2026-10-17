#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate PUBLIC, TEST-ONLY P-256 fixtures with the local OpenSSL command.

Keys/messages are reproducible. OpenSSL ECDSA signatures are randomized and
therefore change when regenerating; verification, not byte equality, is tested.
Never use these deliberately public private scalars in an application identity.
"""

import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def b64(value):
    return base64.b64encode(value).decode("ascii")


def run(*arguments):
    return subprocess.run(arguments, capture_output=True, check=True).stdout


def der_integer(value):
    encoded = value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")
    if encoded[0] & 0x80:
        encoded = b"\x00" + encoded
    return b"\x02" + bytes([len(encoded)]) + encoded


def der_signature(r, s):
    payload = der_integer(r) + der_integer(s)
    return b"\x30" + bytes([len(payload)]) + payload


def generate():
    vectors = []
    with tempfile.TemporaryDirectory(prefix="anice-public-identity-fixture-") as folder:
        directory = Path(folder)
        for scalar, platform, name, message in [
            (3, "android", "Android vector", b"aniCe identity interoperability vector 1\n"),
            (43, "macos", "Mac vector", bytes.fromhex("0001027f80feff") + b"aniCe\x00identity"),
        ]:
            # RFC 5915 ECPrivateKey containing only the test scalar and named curve.
            private_der = (
                bytes.fromhex("30310201010420")
                + scalar.to_bytes(32, "big")
                + bytes.fromhex("a00a06082a8648ce3d030107")
            )
            private_file = directory / "public-test-key.der"
            private_file.write_bytes(private_der)
            pem_file = directory / "public-test-key.pem"
            pem_file.write_bytes(run("openssl", "ec", "-inform", "DER", "-in", str(private_file)))
            subject_public_key_info = run(
                "openssl", "ec", "-inform", "DER", "-in", str(private_file), "-pubout", "-outform", "DER"
            )
            point = subject_public_key_info[-65:]
            assert len(subject_public_key_info) == 91 and point[0] == 4
            public_file = directory / "public-test-key.pub.pem"
            public_file.write_bytes(run("openssl", "ec", "-in", str(pem_file), "-pubout"))
            message_file = directory / "message.bin"
            message_file.write_bytes(message)
            signature = run("openssl", "dgst", "-sha256", "-sign", str(pem_file), str(message_file))
            signature_file = directory / "signature.der"
            signature_file.write_bytes(signature)
            run("openssl", "dgst", "-sha256", "-verify", str(public_file), "-signature", str(signature_file), str(message_file))
            identity = {
                "identitySchemaVersion": 1,
                "deviceId": "11111111-2222-4333-8444-555555555555" if platform == "android" else "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                "deviceName": name,
                "platform": platform,
                "algorithm": "ECDSA_P256_SHA256",
                "publicKey": b64(point),
                "fingerprint": hashlib.sha256(point).hexdigest(),
            }
            vectors.append({
                "name": "p256-scalar-" + str(scalar),
                "privateScalarHex": scalar.to_bytes(32, "big").hex(),
                "xHex": point[1:33].hex(),
                "yHex": point[33:].hex(),
                "publicKeyHex": point.hex(),
                "identity": identity,
                "messageBase64": b64(message),
                "signatureBase64": b64(signature),
            })

    invalid_identities = []

    def invalid_identity(name, changes=None, missing=None):
        identity = copy.deepcopy(vectors[0]["identity"])
        identity.update(changes or {})
        if missing:
            del identity[missing]
        invalid_identities.append({"name": name, "identity": identity})

    invalid_identity("missing-name", missing="deviceName")
    invalid_identity("unsupported-version", {"identitySchemaVersion": 2})
    invalid_identity("string-version", {"identitySchemaVersion": "1"})
    invalid_identity("boolean-version", {"identitySchemaVersion": True})
    invalid_identity("uppercase-uuid", {"deviceId": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"})
    invalid_identity("non-v4-uuid", {"deviceId": "11111111-2222-5333-8444-555555555555"})
    invalid_identity("empty-name", {"deviceName": ""})
    invalid_identity("numeric-name", {"deviceName": 123})
    invalid_identity("untrimmed-name", {"deviceName": " Android "})
    invalid_identity("long-name", {"deviceName": "a" * 65})
    invalid_identity("unknown-platform", {"platform": "linux"})
    invalid_identity("unknown-algorithm", {"algorithm": "Ed25519"})
    invalid_identity("unknown-field", {"unexpected": True})
    point = bytes.fromhex(vectors[0]["publicKeyHex"])
    invalid_identity("base64-missing-padding", {"publicKey": b64(point).rstrip("=")})
    invalid_identity("base64-whitespace", {"publicKey": b64(point) + "\n"})
    # Nonzero unused padding bits decode to the same bytes with lenient decoders.
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    canonical = b64(point)
    invalid_identity("base64-noncanonical-padding-bits", {
        "publicKey": canonical[:-2] + alphabet[alphabet.index(canonical[-2]) + 1] + "="
    })
    invalid_identity("wrong-public-key-length", {"publicKey": b64(point[:-1])})
    wrong_prefix = b"\x05" + point[1:]
    invalid_identity("wrong-public-key-prefix", {"publicKey": b64(wrong_prefix), "fingerprint": hashlib.sha256(wrong_prefix).hexdigest()})
    off_curve = b"\x04" + bytes(64)
    invalid_identity("off-curve-point", {"publicKey": b64(off_curve), "fingerprint": hashlib.sha256(off_curve).hexdigest()})
    invalid_identity("fingerprint-mismatch", {"fingerprint": "0" * 64})
    invalid_identity("uppercase-fingerprint", {"fingerprint": vectors[0]["identity"]["fingerprint"].upper()})

    invalid_signatures = []
    original_signature = base64.b64decode(vectors[0]["signatureBase64"])

    def invalid_signature(name, signature=original_signature, message=None, identity=None):
        invalid_signatures.append({
            "name": name,
            "identity": copy.deepcopy(identity or vectors[0]["identity"]),
            "messageBase64": vectors[0]["messageBase64"] if message is None else b64(message),
            "signatureBase64": b64(signature),
        })

    invalid_signature("modified-message", message=b"modified message")
    invalid_signature("different-public-key", identity=vectors[1]["identity"])
    invalid_signature("empty-signature", signature=b"")
    invalid_signature("truncated-signature", signature=original_signature[:-1])
    invalid_signature("trailing-byte", signature=original_signature + b"\x00")
    invalid_signature("nonminimal-sequence-length", signature=b"\x30\x81" + original_signature[1:])
    invalid_signature("negative-r", signature=bytes.fromhex("3006020180020101"))
    invalid_signature("zero-r", signature=der_signature(0, 1))
    invalid_signature("zero-s", signature=der_signature(1, 0))
    order = int("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)
    invalid_signature("r-out-of-range", signature=der_signature(order, 1))
    invalid_signature("s-out-of-range", signature=der_signature(1, order))
    # Add a superfluous leading zero to an otherwise valid R value.
    r_length = original_signature[3]
    padded_r = b"\x02" + bytes([r_length + 1]) + b"\x00" + original_signature[4:4 + r_length]
    rest = original_signature[4 + r_length:]
    invalid_signature("nonminimal-r", signature=b"\x30" + bytes([len(padded_r + rest)]) + padded_r + rest)
    return {
        "fixtureVersion": 1,
        "notice": "PUBLIC TEST-ONLY PRIVATE SCALARS. Never use these keys in an application identity. Signatures are verified, not compared against newly generated signatures.",
        "valid": vectors,
        "invalidIdentities": invalid_identities,
        "invalidSignatures": invalid_signatures,
    }


def public_key_der(point):
    """Wraps an uncompressed P-256 point in a SubjectPublicKeyInfo structure."""
    assert len(point) == 65 and point[0] == 4
    return bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200") + point


def verify_signature(point, message, signature, directory):
    """Uses OpenSSL, a third implementation, rather than either application verifier."""
    der = directory / "identity-public.der"
    pem = directory / "identity-public.pem"
    message_file = directory / "message.bin"
    signature_file = directory / "signature.der"
    der.write_bytes(public_key_der(point))
    message_file.write_bytes(message)
    signature_file.write_bytes(signature)
    run("openssl", "pkey", "-pubin", "-inform", "DER", "-in", str(der), "-out", str(pem))
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-verify", str(pem), "-signature", str(signature_file), str(message_file)],
        capture_output=True, text=True,
    )
    return result.returncode == 0


def without_signatures(document):
    """Signatures are randomized; compare every other fixture field exactly.

    Oracle rows are independent named cases, so their order is not part of the
    contract.  Sorting keeps the drift check sensitive to added, removed or
    changed cases without failing on a harmless reordering.
    """
    normalized = copy.deepcopy(document)
    for row in normalized["valid"]:
        row.pop("signatureBase64", None)
    for row in normalized["invalidSignatures"]:
        row.pop("signatureBase64", None)
    for key in ("valid", "invalidIdentities", "invalidSignatures"):
        normalized[key].sort(key=lambda row: row.get("name", ""))
    return normalized


def check(path):
    """Detects fixture drift and independently verifies every committed signature."""
    committed = json.loads(path.read_text(encoding="utf-8"))
    generated = generate()
    if without_signatures(committed) != without_signatures(generated):
        raise SystemExit("Identity fixtures differ outside randomized signatures; regenerate them and review the diff.")
    if len(committed["valid"]) < 2 or len(committed["invalidIdentities"]) < 21 or len(committed["invalidSignatures"]) < 12:
        raise SystemExit("Identity fixture inventory shrank below its documented floor.")
    # OpenSSL parses one DER signature and ignores trailing bytes.  The
    # application contract rejects that non-canonical encoding, so OpenSSL
    # acceptance is expected for this one case only; it is not a crypto oracle.
    openssl_lenient = {"trailing-byte"}
    with tempfile.TemporaryDirectory(prefix="anice-public-identity-check-") as folder:
        directory = Path(folder)
        for row in committed["valid"]:
            point = bytes.fromhex(row["publicKeyHex"])
            message = base64.b64decode(row["messageBase64"], validate=True)
            signature = base64.b64decode(row["signatureBase64"], validate=True)
            if not verify_signature(point, message, signature, directory):
                raise SystemExit("Committed valid identity signature failed OpenSSL verification: " + row["name"])
        for row in committed["invalidSignatures"]:
            point = base64.b64decode(row["identity"]["publicKey"], validate=True)
            message = base64.b64decode(row["messageBase64"], validate=True)
            signature = base64.b64decode(row["signatureBase64"], validate=True)
            accepted = verify_signature(point, message, signature, directory)
            if row["name"] in openssl_lenient:
                if not accepted:
                    raise SystemExit("OpenSSL unexpectedly rejected the canonicality-negative case: " + row["name"])
            elif accepted:
                raise SystemExit("Committed invalid identity signature was accepted by OpenSSL: " + row["name"])
    print(f"Identity fixtures match and {len(committed['valid'])} signatures verify with OpenSSL.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="JSON file to create or replace")
    parser.add_argument("--check", action="store_true", help="verify the committed fixture instead of rewriting it")
    options = parser.parse_args()
    if options.check:
        if options.output:
            parser.error("--output cannot be combined with --check")
        check(Path(__file__).with_name("identity-vectors.json"))
    else:
        if options.output is None:
            parser.error("--output is required unless --check is used")
        options.output.write_text(json.dumps(generate(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
