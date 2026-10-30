# SPDX-License-Identifier: GPL-3.0-or-later
# Checks record fixtures against independent AES-GCM encryption and authenticated mutations.
import json
import unittest
from pathlib import Path
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from generate_record_vectors import generate


class RecordOracleTests(unittest.TestCase):
    def test_exact_regeneration_and_authenticated_mutations(self):
        fixtures = json.loads(Path(__file__).with_name("record-vectors.json").read_text())
        self.assertGreaterEqual(len(fixtures["valid"]), 3)
        self.assertGreaterEqual(len(fixtures["invalid"]), 15)
        self.assertEqual(fixtures, generate())
        for row in fixtures["valid"]:
            record = bytes.fromhex(row["recordHex"])
            key = bytes.fromhex(row["keyHex"])
            nonce = bytes.fromhex(row["nonceHex"])
            aad = bytes.fromhex(row["aadHex"])
            self.assertEqual(AESGCM(key).decrypt(nonce, record[14:], aad), bytes.fromhex(row["plainHex"]))
            altered = bytearray(record[14:]);altered[-1] ^= 1
            with self.assertRaises(InvalidTag):
                AESGCM(key).decrypt(nonce, bytes(altered), aad)
