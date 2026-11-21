"""Request-scoped catalog distribution. IP location is resolved locally, never from client labels."""
from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass
import hashlib
import ipaddress
import os
from pathlib import Path
import re
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS app_distribution (
 app_id INTEGER PRIMARY KEY REFERENCES app(id) ON DELETE CASCADE,
 region TEXT NOT NULL CHECK(region IN ('ordinary','overseas','review')),
 review_source TEXT NOT NULL DEFAULT '',
 reason TEXT NOT NULL DEFAULT '',
 content_hash TEXT NOT NULL DEFAULT '',
 updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_app_distribution_region ON app_distribution(region,app_id);
CREATE TABLE IF NOT EXISTS ai_review_control (
 id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO ai_review_control(id,enabled) VALUES(1,0);
CREATE TABLE IF NOT EXISTS ai_review_signal (
 app_id INTEGER PRIMARY KEY REFERENCES app(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL DEFAULT 1, updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS personal_install (
 account_id TEXT NOT NULL, client_id TEXT NOT NULL,
 app_id INTEGER NOT NULL REFERENCES app(id) ON DELETE CASCADE,
 bundle_name TEXT NOT NULL, installed_code INTEGER NOT NULL, updated_at INTEGER NOT NULL,
 PRIMARY KEY(account_id,client_id,app_id,bundle_name)
);
CREATE INDEX IF NOT EXISTS idx_personal_install_app ON personal_install(account_id,app_id);
CREATE VIEW IF NOT EXISTS region_catalog_app AS
 SELECT a.* FROM app a LEFT JOIN app_distribution d ON d.app_id=a.id
 WHERE (store_distribution_scope()='internal'
   OR COALESCE(d.region,'ordinary')='ordinary'
   OR (d.region='overseas' AND store_distribution_scope()='overseas'))
 AND (store_distribution_filter()='' OR d.region=store_distribution_filter());
"""

@dataclass(frozen=True)
class Access:
    scope: str = 'ordinary'
    country: str = ''

_access: ContextVar[Access] = ContextVar('catalog_distribution', default=Access('internal'))
_filter: ContextVar[str] = ContextVar('catalog_region_filter', default='')
_geo_lock = threading.RLock()
_reader = None
_reader_signature = None
_next_stat = 0.0


def register(conn) -> None:
    # Each statement sees one immutable request scope. Prepared statements are
    # deliberately reused in tests across scopes to verify the functions reset.
    conn.create_function('store_distribution_scope', 0, lambda: _access.get().scope, deterministic=True)
    conn.create_function('store_distribution_filter', 0, _filter.get, deterministic=True)


def client_ip(handler) -> str:
    peer = handler.client_address[0]
    try:
        address = ipaddress.ip_address(peer)
        if address.is_loopback:
            # nginx overwrites X-Real-IP. Untrusted peers cannot choose their scope.
            forwarded = handler.headers.get('X-Real-IP')
            if forwarded:
                return str(ipaddress.ip_address(forwarded.strip()))
        return str(address)
    except ValueError:
        return ''


def country(ip: str) -> str:
    global _reader, _reader_signature, _next_stat
    try:
        address = ipaddress.ip_address(ip)
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
        if not address.is_global:
            return ''
    except ValueError:
        return ''
    path = Path(os.environ.get('HAPSTORE_GEOIP_DB', '/var/lib/hapstore/geoip/dbip-country-lite.mmdb'))
    with _geo_lock:
        now = time.monotonic()
        if now >= _next_stat:
            _next_stat = now + 60
            try:
                stat = path.stat()
                signature = (str(path), stat.st_mtime_ns, stat.st_size)
                if signature != _reader_signature:
                    import maxminddb
                    replacement = maxminddb.open_database(str(path))
                    old, _reader = _reader, replacement
                    _reader_signature = signature
                    if old is not None:
                        old.close()
            except Exception:
                # A valid older reader can survive a failed atomic database update.
                pass
        if _reader is None:
            return ''
        try:
            data = _reader.get(str(address)) or {}
            iso = str((data.get('country') or {}).get('iso_code') or '').upper()
            return iso if re.fullmatch('[A-Z]{2}', iso) and iso not in {'ZZ','XX','AP','EU'} else ''
        except Exception:
            return ''


@contextmanager
def request(ip: str):
    iso = country(ip)
    token = _access.set(Access('overseas' if iso and iso != 'CN' else 'ordinary', iso))
    try:
        yield _access.get()
    finally:
        _access.reset(token)


@contextmanager
def scope(value: str):
    if value not in ('internal', 'ordinary', 'overseas'):
        raise ValueError('invalid catalog scope')
    token = _access.set(Access(value))
    try:
        yield
    finally:
        _access.reset(token)


@contextmanager
def only_region(value: str):
    token = _filter.set(value)
    try:
        yield
    finally:
        _filter.reset(token)


def cache_key() -> tuple[str, str]:
    return _access.get().scope, _filter.get()


def region(conn, app_id: int) -> str:
    row = conn.execute('SELECT region FROM app_distribution WHERE app_id=?', (app_id,)).fetchone()
    return row[0] if row else 'ordinary'


def allows(conn, app_id: int) -> bool:
    value = region(conn, app_id)
    return (_access.get().scope == 'internal' or value == 'ordinary' or
            value == 'overseas' and _access.get().scope == 'overseas')


def ordinary_notice(conn, app_id: int) -> bool:
    # Public broadcasts/cache cannot infer a receiver's current network. Personal
    # update delivery instead validates its account-bound watch/follow records.
    return region(conn, app_id) == 'ordinary'


def flags(conn) -> dict:
    visible = (_access.get().scope == 'overseas' and bool(conn.execute(
        "SELECT 1 FROM app_distribution d JOIN app a ON a.id=d.app_id "
        "WHERE d.region='overseas' AND a.status='published' LIMIT 1").fetchone()))
    return dict(network_scope='overseas' if _access.get().scope == 'overseas' else 'ordinary',
                show_overseas_section=visible,
                geoip_attribution=dict(name='IP Geolocation by DB-IP', url='https://db-ip.com'))


# Conservative bootstrap: a proxy setting or an ordinary app merely mentioning
# proxies is not a traffic-proxy client. AI integration can replace this review
# source after the operator configures a model; this is not labelled AI approval.
_OVERSEAS = re.compile(
    r'\bmihomo\b|\bclashmeta\b|\bsing[- ]box\b|\bv2ray(?:ng|h)?\b|\bxray\b|'
    r'\b(?:vpn|proxy)\s+client\b|VPN(?:客户端|扩展)|代理(?:客户端|工具|软件)|'
    r'翻墙|\b(?:FlClash|ArkClash|ClashBox|Clash[- ]Mate|NekoBox|SSRVPN|FireflyVPN)\b', re.I)


def bootstrap_review(conn, app_id: int, metadata: dict) -> None:
    # A cheap durable signal, committed with metadata. No network/model calls
    # run in the listing or collector request. CAS consumption prevents loss.
    conn.execute('''INSERT INTO ai_review_signal(app_id,revision,updated_at)
        SELECT ?,1,? WHERE EXISTS(SELECT 1 FROM ai_review_control WHERE id=1 AND enabled=1)
        ON CONFLICT(app_id) DO UPDATE SET revision=revision+1,updated_at=excluded.updated_at''',
        (app_id, int(time.time())))
    if conn.execute('SELECT 1 FROM app_distribution WHERE app_id=?', (app_id,)).fetchone():
        return
    text = '\n'.join(str(metadata.get(k) or '') for k in ('repo_full_name','display_name','description','summary'))
    found = _OVERSEAS.search(text)
    if found:
        conn.execute('INSERT INTO app_distribution(app_id,region,review_source,reason,content_hash,updated_at) VALUES(?,?,?,?,?,?)',
            (app_id, 'overseas', 'bootstrap-purpose-rule', '代理客户端用途线索：' + found.group(0),
             hashlib.sha256(text.encode()).hexdigest(), int(time.time())))
    else:
        # Existing catalog entries retain their decisions. A new, unclassified
        # listing waits for background review before entering public feeds.
        conn.execute('''INSERT INTO app_distribution(app_id,region,review_source,reason,updated_at)
            SELECT ?,'review','ai-pending','等待后台 AI 分区审核',?
            WHERE EXISTS(SELECT 1 FROM ai_review_control WHERE id=1 AND enabled=1)''',
            (app_id, int(time.time())))
