import os
import tempfile
import threading
import unittest

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from hapstore import db, identity_vault


class IdentityVaultTest(unittest.TestCase):
    def test_first_write_wins_and_ciphertext_is_account_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            db.DB_PATH = os.path.join(directory, "store.db")
            db._local = threading.local()
            db._initialized = False
            identity_vault.KEY_PATH = os.path.join(directory, "vault.key")
            db.init_db()
            private_key = ec.generate_private_key(ec.SECP256R1())
            pem = private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ).decode("ascii")

            self.assertTrue(identity_vault.put_once("account-a", "123", pem))
            self.assertFalse(identity_vault.put_once("account-a", "456", pem))
            self.assertEqual(identity_vault.get("account-a"),
                             {"cert_id": "123", "private_key_pem": pem})
            self.assertIsNone(identity_vault.get("account-b"))
            self.assertEqual(os.stat(identity_vault.KEY_PATH).st_mode & 0o777, 0o600)
            row = db.connect().execute(
                "SELECT ciphertext FROM signing_identity WHERE account_id='account-a'"
            ).fetchone()
            self.assertNotIn(pem.encode("ascii"), row["ciphertext"])


if __name__ == "__main__":
    unittest.main()
