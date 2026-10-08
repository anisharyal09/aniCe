# SPDX-License-Identifier: GPL-3.0-or-later
import json
from pathlib import Path
import unittest

import cbor2
from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

import generate_session_vectors as oracle


class SessionOracleTests(unittest.TestCase):
    def test_published_rfc9529_derivations(self):
        v = json.loads(Path(__file__).with_name("rfc9529-components.json").read_text())
        b = lambda key: bytes.fromhex(v[key + "Hex"])
        self.assertEqual(oracle.digest(oracle.seq(b("gy"), oracle.digest(b("message1")))), b("th2"))
        self.assertEqual(oracle.extract(b("th2"), b("z")), b("prk"))
        self.assertEqual(oracle.kdf(b("prk"), 2, b("context2"), 32), b("mac2"))
        self.assertEqual(oracle.kdf(b("prk"), 0, b("th2"), len(b("plaintext2"))), b("keystream2"))
        self.assertEqual(oracle.digest(oracle.enc(b("th2")) + b("plaintext2") + b("credentialR")), b("th3"))
        self.assertEqual(oracle.digest(oracle.enc(b("th3")) + b("plaintext3") + b("credentialI")), b("th4"))
        self.assertEqual(oracle.kdf(b("prk"), 7, b("th4"), 32), b("prkOut"))
        self.assertEqual(oracle.kdf(b("prkOut"), 10, b"", 32), b("prkExporter"))

    def test_suite5_signatures_aead_and_mutations(self):
        fixtures = json.loads(Path(__file__).with_name("session-vectors.json").read_text())
        self.assertGreaterEqual(len(fixtures["valid"]), 3)
        self.assertGreaterEqual(len(fixtures["invalid"]), 15)
        for v in fixtures["valid"]:
            b = lambda key: bytes.fromhex(v[key + "Hex"])
            for role, stage in [("responder", 2), ("initiator", 3)]:
                key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), bytes.fromhex(v[role]["publicHex"]))
                raw = b(f"signature{stage}")
                signature = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
                key.verify(signature, b(f"signingInput{stage}"), ec.ECDSA(hashes.SHA256()))
                with self.assertRaises(InvalidSignature):
                    key.verify(signature, b(f"signingInput{stage}") + b"\x00", ec.ECDSA(hashes.SHA256()))
            for stage, plaintext in [(3, b("plaintext3")), (4, b"")]:
                cipher = ChaCha20Poly1305(b(f"k{stage}"))
                wire = cbor2.loads(b(f"message{stage}"))
                self.assertEqual(cipher.decrypt(b(f"iv{stage}"), wire, b(f"aad{stage}")), plaintext)
                with self.assertRaises(InvalidTag):
                    cipher.decrypt(b(f"iv{stage}"), wire, b(f"aad{stage}") + b"\x00")
            self.assertNotEqual(b("export-key-1"), b("export-key-2"))
            self.assertNotEqual(b("export-iv-1"), b("export-iv-2"))

    def test_exact_regeneration(self):
        self.assertEqual(oracle.generate(), json.loads(Path(__file__).with_name("session-vectors.json").read_text()))


if __name__ == "__main__":
    unittest.main()
