#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# /// script
# dependencies = ["cryptography"]
# ///
"""Independent pairing test-vector generator.

Uses standard Python and the reference 'cryptography' library to produce
independent cryptographic test vectors without relying on application code.
Run with:
    uv run protocol/test-vectors/generate_pairing_vectors.py
"""

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


def encode_fields(*elements: bytes) -> bytes:
    """Encodes arguments as uint32-length-prefixed fields."""
    return b"".join(struct.pack(">I", len(e)) + e for e in elements)


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def hkdf_derive(ikm: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def public_uncompressed_bytes(key: ec.EllipticCurvePrivateKey) -> bytes:
    return key.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )


def generate_vectors() -> dict:
    # Deterministic test keys from fixed private scalars
    client_key = ec.derive_private_key(1, ec.SECP256R1())
    server_key = ec.derive_private_key(2, ec.SECP256R1())

    client_pub = public_uncompressed_bytes(client_key)
    server_pub = public_uncompressed_bytes(server_key)

    # Fixed synthetic nonces and parameters
    rendezvous = bytes(range(16))
    psk = bytes(range(32))
    client_nonce = bytes(range(32, 64))
    server_nonce = bytes(range(64, 96))
    server_fingerprint = sha256(server_pub)

    # Transcript and transcript hash
    method_byte = b"\x01"  # QR method
    transcript = encode_fields(
        b"aniCe pairing v1",
        method_byte,
        rendezvous,
        client_nonce,
        server_nonce,
        client_pub,
        server_pub,
    )
    transcript_hash = sha256(transcript)

    # ECDH shared secret & HKDF bootstrap key derivation
    ecdh_secret = client_key.exchange(ec.ECDH(), server_key.public_key())
    bootstrap_info = encode_fields(b"aniCe qr bootstrap v1", transcript_hash)
    bootstrap_key = hkdf_derive(ecdh_secret, psk, bootstrap_info, 32)

    def derive(label: bytes) -> bytes:
        return hkdf_derive(bootstrap_key, transcript_hash, b"aniCe pairing v1 " + label, 32)

    server_auth_key = derive(b"server-auth")
    client_auth_key = derive(b"client-auth")
    confirm_key = derive(b"channel-confirm")
    c2s_key = derive(b"client-to-server")

    # Authentication MACs
    server_mac = hmac.digest(server_auth_key, transcript, "sha256")
    client_mac = hmac.digest(client_auth_key, transcript, "sha256")
    confirmation = hmac.digest(confirm_key, transcript, "sha256")

    # Encrypted message vector: Inner approve message (type 12)
    plain = b"\x0c"  # Message type 12 (approve)
    counter = bytes(8)  # Counter 0
    aad = encode_fields(b"aniCe pairing encrypted v1", transcript_hash, b"\x01", counter)
    nonce_12 = bytes(12)  # 4 zero bytes + 8-byte counter (all zeros)
    ciphertext_and_tag = AESGCM(c2s_key).encrypt(nonce_12, plain, aad)
    # Message type 7 (encrypted) with outer fields: counter, ciphertext
    encrypted_approval = b"\x07" + encode_fields(counter, ciphertext_and_tag)

    # Canonical QR text (version 1, 81 decoded bytes)
    qr_payload = b"\x01" + rendezvous + psk + server_fingerprint
    qr_text = "anice:pair:1:" + base64.urlsafe_b64encode(qr_payload).decode("ascii").rstrip("=")

    return {
        "fixtureVersion": 1,
        "qr": qr_text,
        "rendezvousHex": rendezvous.hex(),
        "secretHex": psk.hex(),
        "fingerprintHex": server_fingerprint.hex(),
        "clientPublicHex": client_pub.hex(),
        "serverPublicHex": server_pub.hex(),
        "transcriptHex": transcript.hex(),
        "transcriptHashHex": transcript_hash.hex(),
        "sharedSecretHex": ecdh_secret.hex(),
        "bootstrapKeyHex": bootstrap_key.hex(),
        "serverMacHex": server_mac.hex(),
        "clientMacHex": client_mac.hex(),
        "confirmationHex": confirmation.hex(),
        "encryptedApprovalHex": encrypted_approval.hex(),
        "invalidQR": [
            {"text": qr_text + "=", "reason": "noncanonical"},
            {"text": qr_text.replace("anice:", "other:"), "reason": "scheme"},
            {"text": qr_text[:-1], "reason": "length"},
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify the committed fixture instead of rewriting it")
    options = parser.parse_args()
    root = generate_vectors()
    output_path = Path(__file__).with_name("pairing-vectors.json")
    content = json.dumps(root, indent=2) + "\n"
    if options.check:
        if output_path.read_text() != content:
            raise SystemExit("Pairing fixtures differ; regenerate them and review the diff.")
        print(f"Pairing fixtures match: {output_path.name}")
    else:
        output_path.write_text(content)
        print(f"Wrote test vectors to {output_path}")


if __name__ == "__main__":
    main()
