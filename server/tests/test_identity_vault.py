import os
import tempfile
import threading
import unittest

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from hapstore import db, identity_vault
from hapstore.app import h_put_signing_identity, h_get_signing_identity, ApiError


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
                             {"cert_id": "123", "private_key_pem": pem, "revision": 1})
            self.assertIsNone(identity_vault.get("account-b"))
            self.assertEqual(os.stat(identity_vault.KEY_PATH).st_mode & 0o777, 0o600)
            row = db.connect().execute(
                "SELECT ciphertext FROM signing_identity WHERE account_id='account-a'"
            ).fetchone()
            self.assertNotIn(pem.encode("ascii"), row["ciphertext"])


class IdentityRotationTest(unittest.TestCase):
    """证书轮换：旧证书被删或过期后，备份必须能换掉。

    否则换机重装取回的是一把配不上任何证书的私钥，而 first-write-wins 会永远
    发这把死身份 —— 只能到服务器上手工改库才能恢复。
    """

    def _pem(self) -> str:
        key = ec.generate_private_key(ec.SECP256R1())
        return key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ).decode("ascii")

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        db.DB_PATH = os.path.join(self._tmp.name, "store.db")
        db._local = threading.local()
        db._initialized = False
        identity_vault.KEY_PATH = os.path.join(self._tmp.name, "vault.key")
        db.init_db()

    def tearDown(self):
        self._tmp.cleanup()

    def test_replace_rotates_when_expectation_matches(self):
        old, new = self._pem(), self._pem()
        self.assertTrue(identity_vault.put_once("account-a", "111", old))
        self.assertTrue(identity_vault.replace("account-a", "111", "222", new, 1))
        self.assertEqual(identity_vault.get("account-a"),
                         {"cert_id": "222", "private_key_pem": new, "revision": 2})
        self.assertEqual(identity_vault.get_certificate("account-a", "111")["private_key_pem"], old)

    def test_independent_devices_backup_and_restore_exact_certificate(self):
        auth, first, second = ('account-a', 'test'), self._pem(), self._pem()
        for cert, pem in [('111', first), ('222', second)]:
            body = {'backup_scope': 'certificate', 'cert_id': cert, 'private_key_pem': pem}
            self.assertTrue(h_put_signing_identity(body, auth)['synced'])
            self.assertTrue(h_put_signing_identity(body, auth)['synced'])
            self.assertEqual(h_get_signing_identity(auth, cert)['identity']['private_key_pem'], pem)
        self.assertEqual(identity_vault.get('account-a')['cert_id'], '111')
        self.assertIsNone(h_get_signing_identity(('account-b', 'test'), '222')['identity'])
        self.assertIsNone(h_get_signing_identity(auth, '333')['identity'])

    def test_certificate_backup_cannot_replace_key_with_same_cert_id(self):
        auth, pem = ('account-a', 'test'), self._pem()
        body = {'backup_scope': 'certificate', 'cert_id': '111', 'private_key_pem': pem}
        h_put_signing_identity(body, auth)
        with self.assertRaises(ApiError):
            h_put_signing_identity({**body, 'private_key_pem': self._pem()}, auth)
        self.assertEqual(identity_vault.get_certificate('account-a', '111')['private_key_pem'], pem)

    def test_legacy_backup_can_be_read_by_certificate_without_migration(self):
        pem = self._pem()
        identity_vault.put_once('account-a', '111', pem)
        self.assertEqual(identity_vault.get_certificate('account-a', '111')['private_key_pem'], pem)
        self.assertIsNone(identity_vault.get_certificate('account-a', '222'))

    def test_certificate_ciphertext_is_bound_to_account_and_cert_id(self):
        from cryptography.exceptions import InvalidTag
        pem = self._pem()
        identity_vault.put_certificate('account-a', '111', pem)
        conn = db.connect()
        row = conn.execute('SELECT nonce,ciphertext FROM signing_identity_certificate').fetchone()
        self.assertNotIn(pem.encode(), row['ciphertext'])
        for account, cert in [('account-b', '111'), ('account-a', '222')]:
            conn.execute('INSERT INTO signing_identity_certificate(account_id,cert_id,nonce,ciphertext) VALUES (?,?,?,?)',
                         (account, cert, row['nonce'], row['ciphertext']))
            conn.commit()
            with self.assertRaises(InvalidTag):
                identity_vault.get_certificate(account, cert)

    def test_replace_refuses_when_expectation_is_stale(self):
        """别人已经换过了：拿着过期的期望值不能再覆盖回去。"""
        first, second, third = self._pem(), self._pem(), self._pem()
        self.assertTrue(identity_vault.put_once("account-a", "111", first))
        self.assertTrue(identity_vault.replace("account-a", "111", "222", second, 1))
        self.assertFalse(identity_vault.replace("account-a", "111", "333", third, 1))
        self.assertEqual(identity_vault.get("account-a"),
                         {"cert_id": "222", "private_key_pem": second, "revision": 2})

    def test_replace_cannot_target_another_account(self):
        """一台从未持有旧身份的机器猜不出 cert_id，也就换不掉别人的证书。"""
        pem = self._pem()
        self.assertTrue(identity_vault.put_once("account-a", "111", pem))
        self.assertFalse(identity_vault.replace("account-b", "111", "999", pem, 1))
        self.assertFalse(identity_vault.replace("account-a", "999", "999", pem, 1))
        self.assertEqual(identity_vault.get("account-a")["cert_id"], "111")

    def test_replace_on_missing_row_creates_nothing(self):
        self.assertFalse(identity_vault.replace("account-c", "111", "222", self._pem(), 1))
        self.assertIsNone(identity_vault.get("account-c"))

    def test_rotation_keeps_ciphertext_account_bound(self):
        old, new = self._pem(), self._pem()
        identity_vault.put_once("account-a", "111", old)
        self.assertTrue(identity_vault.replace("account-a", "111", "222", new, 1))
        row = db.connect().execute(
            "SELECT nonce, ciphertext FROM signing_identity WHERE account_id='account-a'"
        ).fetchone()
        self.assertNotIn(new.encode("ascii"), row["ciphertext"])
        # 换过之后仍然只有本账号解得开（AAD 绑 account_id）
        self.assertEqual(identity_vault.get("account-a")["private_key_pem"], new)

    def test_revision_rejects_aba_certificate_id(self):
        pem = self._pem()
        identity_vault.put_once('account-a', '111', pem)
        self.assertTrue(identity_vault.replace('account-a', '111', '222', pem, 1))
        self.assertTrue(identity_vault.replace('account-a', '222', '111', pem, 2))
        self.assertFalse(identity_vault.replace('account-a', '111', '333', pem, 1))
        self.assertEqual(identity_vault.get('account-a')['revision'], 3)

    def test_api_requires_revision_and_rejects_stale_client(self):
        pem = self._pem()
        auth = ('account-a', 'test')
        first = h_put_signing_identity({'cert_id': '111', 'private_key_pem': pem}, auth)
        self.assertEqual(first['revision'], 1)
        rotated = h_put_signing_identity({'cert_id': '222', 'private_key_pem': pem,
            'replace_cert_id': '111', 'replace_revision': 1}, auth)
        self.assertEqual(rotated['revision'], 2)
        for body in [
            {'cert_id': '111', 'private_key_pem': pem},
            {'cert_id': '111', 'private_key_pem': pem, 'replace_cert_id': '222'},
            {'cert_id': '333', 'private_key_pem': pem,
             'replace_cert_id': '111', 'replace_revision': 1},
        ]:
            with self.assertRaises(ApiError):
                h_put_signing_identity(body, auth)
        self.assertEqual(identity_vault.get('account-a')['cert_id'], '222')

    def test_api_retry_is_idempotent_and_rejects_wrong_key(self):
        auth, pem = ('account-a', 'test'), self._pem()
        h_put_signing_identity({'cert_id': '111', 'private_key_pem': pem}, auth)
        body = {'cert_id': '222', 'private_key_pem': pem,
                'replace_cert_id': '111', 'replace_revision': 1}
        h_put_signing_identity(body, auth)
        again = h_put_signing_identity(body, auth)
        self.assertTrue(again['synced'])
        self.assertEqual(again['revision'], 2)
        with self.assertRaises(ApiError):
            h_put_signing_identity({'cert_id': '222', 'private_key_pem': self._pem()}, auth)

    def test_existing_database_migrates_revision_without_changing_backup(self):
        pem = self._pem()
        identity_vault.put_once('account-a', '111', pem)
        conn = db.connect()
        conn.execute('ALTER TABLE signing_identity DROP COLUMN revision')
        conn.commit()
        db._initialized = False
        db.init_db()
        self.assertEqual(identity_vault.get('account-a'),
                         {'cert_id': '111', 'private_key_pem': pem, 'revision': 1})


if __name__ == "__main__":
    unittest.main()
