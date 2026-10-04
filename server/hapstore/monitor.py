"""Resource snapshot and daily verified-account counts for the monitor app.

The GitHub response is cached so opening the dashboard does not generate a
new outbound request on every refresh. No credentials or environment values
are included in the response.
"""

from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import json
import os
import sqlite3
import ssl
import threading
import time
import urllib.request
from typing import Any

from . import db

_STARTED = time.monotonic()
_GITHUB_LOCK = threading.Lock()
_GITHUB_CACHE: dict[str, Any] = {}
_GITHUB_CACHE_AT = 0.0
_GITHUB_CACHE_SECONDS = 60
_PASSWORD_ITERATIONS = 600_000
_STORE_TIMEZONE = timezone(timedelta(hours=8))
_PRESENCE_LOCK = threading.Lock()
_PRESENCE_SALT: bytes | None = None
_PRESENCE_DAY = ""
_PRESENCE_SEEN: set[tuple[str, bytes]] = set()
_PRESENCE_CACHE_LIMIT = 8192


def _today() -> str:
    return datetime.now(_STORE_TIMEZONE).date().isoformat()


def _presence_db(c: sqlite3.Connection) -> bytes:
    """Create the small daily counter once and retain a stable hashing salt."""
    global _PRESENCE_SALT
    if _PRESENCE_SALT is None:
        c.execute("""CREATE TABLE IF NOT EXISTS monitor_presence_config (
            id INTEGER PRIMARY KEY CHECK (id = 1), salt BLOB NOT NULL)""")
        c.execute("""CREATE TABLE IF NOT EXISTS monitor_daily_presence (
            day TEXT NOT NULL, kind TEXT NOT NULL, digest BLOB NOT NULL,
            PRIMARY KEY (day, kind, digest)) WITHOUT ROWID""")
        c.execute("INSERT OR IGNORE INTO monitor_presence_config VALUES (1, ?)",
                  (os.urandom(32),))
        c.commit()
        _PRESENCE_SALT = c.execute(
            "SELECT salt FROM monitor_presence_config WHERE id = 1").fetchone()[0]
    return _PRESENCE_SALT


def _record_presence(kind: str, identity: str) -> None:
    if not identity:
        return
    global _PRESENCE_DAY
    day = _today()
    with _PRESENCE_LOCK:
        c = None
        try:
            c = db.connect()
            salt = _presence_db(c)
            if day != _PRESENCE_DAY:
                _PRESENCE_SEEN.clear()
                _PRESENCE_DAY = day
                c.execute("DELETE FROM monitor_daily_presence WHERE day < ?", (day,))
                c.commit()
            digest = hmac.new(salt, f"{day}\0{kind}\0{identity}".encode("utf-8"),
                              hashlib.sha256).digest()[:16]
            key = (kind, digest)
            if key not in _PRESENCE_SEEN:
                c.execute("INSERT OR IGNORE INTO monitor_daily_presence VALUES (?, ?, ?)",
                          (day, kind, digest))
                c.commit()
                if len(_PRESENCE_SEEN) < _PRESENCE_CACHE_LIMIT:
                    _PRESENCE_SEEN.add(key)
        except sqlite3.Error:
            # Monitoring must not turn an otherwise valid store request into a failure.
            if c is not None:
                c.rollback()
            return


def record_authenticated_account(account_id: str) -> None:
    """Record activity only after Huawei identity verification succeeds."""
    _record_presence("account", account_id)


def user_snapshot() -> dict[str, Any]:
    """Known verified accounts and today's active verified accounts."""
    c = db.connect()
    available = {row[0] for row in c.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}
    sources = ("account_avatar", "publisher", "review", "signing_identity",
               "signing_identity_certificate", "submit_draft")
    selects = [f"SELECT account_id FROM {name}" for name in sources if name in available]
    verified_total = c.execute(
        "SELECT COUNT(*) FROM (" + " UNION ".join(selects) + ")"
    ).fetchone()[0] if selects else 0
    with _PRESENCE_LOCK:
        _presence_db(c)
        active = c.execute(
            "SELECT COUNT(*) FROM monitor_daily_presence WHERE day = ? AND kind = 'account'",
            (_today(),)).fetchone()[0]
    return {"verified_total": verified_total,
            "today_verified_accounts": active,
            "day": _today(),
            "timezone": "Asia/Shanghai"}


def hash_password(password: str) -> str:
    """Generate a salted verifier for the server environment, never an app secret."""
    if not password or len(password.encode("utf-8")) > 1024:
        raise ValueError("Password must contain 1 to 1024 UTF-8 bytes")
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt,
                               _PASSWORD_ITERATIONS)
    return f"pbkdf2_sha256${_PASSWORD_ITERATIONS}${salt.hex()}${digest.hex()}"


def _password_parts(encoded: str) -> tuple[int, bytes, bytes] | None:
    try:
        scheme, iterations, salt, digest = encoded.split("$")
        count = int(iterations)
        if scheme != "pbkdf2_sha256" or not 100_000 <= count <= 1_000_000:
            return None
        if len(salt) != 32 or len(digest) != 64:
            return None
        return count, bytes.fromhex(salt), bytes.fromhex(digest)
    except (ValueError, TypeError):
        return None


def password_configured(encoded: str) -> bool:
    return _password_parts(encoded) is not None


def verify_authorization(header: str, encoded: str) -> bool:
    """Basic password authentication; old HAPs may submit the same password as Bearer."""
    parts = _password_parts(encoded)
    if parts is None or len(header) > 2048:
        return False
    try:
        if header.startswith("Basic "):
            decoded = base64.b64decode(header[6:], validate=True).decode("utf-8")
            username, separator, password = decoded.partition(":")
            if username != "monitor" or not separator:
                return False
        elif header.startswith("Bearer "):
            # Compatibility for already installed monitors. No legacy token is accepted.
            password = header[7:]
        else:
            return False
        raw = password.encode("utf-8")
        if not raw or len(raw) > 1024:
            return False
        count, salt, expected = parts
        digest = hashlib.pbkdf2_hmac("sha256", raw, salt, count)
        return hmac.compare_digest(digest, expected)
    except (ValueError, UnicodeError):
        return False


def _meminfo() -> dict[str, int]:
    values: dict[str, int] = {}
    with open("/proc/meminfo", encoding="ascii") as stream:
        for line in stream:
            name, _, amount = line.partition(":")
            if name in {"MemTotal", "MemAvailable", "SwapTotal", "SwapFree"}:
                values[name] = int(amount.strip().split()[0]) * 1024
    return values


def system_snapshot() -> dict[str, Any]:
    """Report available capacity, with explicit units and no host identifiers."""
    mem = _meminfo()
    fs_path = db.DB_PATH if os.path.exists(db.DB_PATH) else (os.path.dirname(db.DB_PATH) or ".")
    fs = os.statvfs(fs_path)
    with open("/proc/self/status", encoding="ascii") as stream:
        process_status = stream.read()
    rss_kib = next((int(line.split()[1]) for line in process_status.splitlines()
                    if line.startswith("VmRSS:")), 0)
    try:
        load_1m, load_5m, load_15m = os.getloadavg()
    except OSError:
        load_1m = load_5m = load_15m = 0.0
    return {
        "cpu_cores": os.cpu_count() or 1,
        "load_1m": round(load_1m, 2),
        "load_5m": round(load_5m, 2),
        "load_15m": round(load_15m, 2),
        "memory_total_bytes": mem["MemTotal"],
        "memory_available_bytes": mem["MemAvailable"],
        "swap_total_bytes": mem.get("SwapTotal", 0),
        "swap_free_bytes": mem.get("SwapFree", 0),
        "disk_total_bytes": fs.f_blocks * fs.f_frsize,
        "disk_available_bytes": fs.f_bavail * fs.f_frsize,
        "inodes_total": fs.f_files,
        "inodes_available": fs.f_favail,
        "api_rss_bytes": rss_kib * 1024,
        "api_uptime_seconds": int(time.monotonic() - _STARTED),
        "db_bytes": os.path.getsize(db.DB_PATH) if os.path.exists(db.DB_PATH) else 0,
    }


def _fetch_github(token: str) -> dict[str, Any]:
    request = urllib.request.Request(
        "https://api.github.com/rate_limit",
        headers={"Accept": "application/vnd.github+json",
                 "User-Agent": "hapstore-monitor/1.0",
                 **({"Authorization": f"Bearer {token}"} if token else {})},
    )
    # The store's service runs without a working HTTP proxy. Force direct TLS.
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ssl.create_default_context())
    )
    with opener.open(request, timeout=5) as response:
        payload = json.load(response)
    resources = payload.get("resources", {})
    result = {}
    for name in ("core", "search", "graphql", "integration_manifest", "code_search"):
        item = resources.get(name)
        if isinstance(item, dict):
            result[name] = {key: int(item[key]) for key in ("limit", "remaining", "reset")
                            if isinstance(item.get(key), (int, float))}
    return {"ok": True, "authenticated": bool(token), "resources": result,
            "checked_at": int(time.time())}


def github_snapshot(token: str) -> dict[str, Any]:
    global _GITHUB_CACHE, _GITHUB_CACHE_AT
    with _GITHUB_LOCK:
        now = time.monotonic()
        if _GITHUB_CACHE and now - _GITHUB_CACHE_AT < _GITHUB_CACHE_SECONDS:
            return dict(_GITHUB_CACHE)
        try:
            result = _fetch_github(token)
        except Exception as exc:  # an unavailable dependency must not hide local metrics
            result = {"ok": False, "authenticated": bool(token),
                      "error": type(exc).__name__, "resources": {},
                      "checked_at": int(time.time())}
        _GITHUB_CACHE = result
        _GITHUB_CACHE_AT = now
        return dict(result)


def snapshot(github_token: str) -> dict[str, Any]:
    return {"service": {"ok": True, "name": "hapstore-api"},
            "system": system_snapshot(),
            "github": github_snapshot(github_token),
            "store": db.stats(),
            "users": user_snapshot()}
