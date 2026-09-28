"""Account-bound signing identity vault.

The key is generated on the server, stored outside the database with mode 0600,
and never sent to clients. Only a Huawei JWT verified by the API handler may
read or create an identity. First write wins to prevent another device from
silently changing the signing certificate used for app updates.
"""

from __future__ import annotations

import os
import threading

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from . import db

KEY_PATH = os.environ.get("HAPSTORE_VAULT_KEY", "/var/lib/hapstore/identity-vault.key")
_key_lock = threading.Lock()


def _key() -> bytes:
    with _key_lock:
        try:
            with open(KEY_PATH, "rb") as stream:
                key = stream.read()
        except FileNotFoundError:
            os.makedirs(os.path.dirname(KEY_PATH), mode=0o700, exist_ok=True)
            key = os.urandom(32)
            try:
                fd = os.open(KEY_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                with open(KEY_PATH, "rb") as stream:
                    key = stream.read()
            else:
                with os.fdopen(fd, "wb") as stream:
                    stream.write(key)
                    stream.flush()
                    os.fsync(stream.fileno())
        if len(key) != 32:
            raise RuntimeError("invalid signing identity vault key")
        return key


def get(account_id: str) -> dict[str, str] | None:
    row = db.connect().execute(
        "SELECT cert_id, nonce, ciphertext FROM signing_identity WHERE account_id=?",
        (account_id,),
    ).fetchone()
    if row is None:
        return None
    pem = AESGCM(_key()).decrypt(row["nonce"], row["ciphertext"], account_id.encode())
    return {"cert_id": row["cert_id"], "private_key_pem": pem.decode("ascii")}


def put_once(account_id: str, cert_id: str, pem: str) -> bool:
    nonce = os.urandom(12)
    ciphertext = AESGCM(_key()).encrypt(nonce, pem.encode("ascii"), account_id.encode())
    conn = db.connect()
    result = conn.execute(
        "INSERT OR IGNORE INTO signing_identity(account_id,cert_id,nonce,ciphertext) "
        "VALUES (?,?,?,?)", (account_id, cert_id, nonce, ciphertext),
    )
    conn.commit()
    return result.rowcount == 1
