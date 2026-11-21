"""Bind a verified GitHub user to a Huawei developer via browser OAuth."""
from __future__ import annotations

import base64
from hashlib import sha256
import json
import os
import re
import secrets
import time
from urllib.error import URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from . import developer_registry as registry

CALLBACK = '/api/v1/developer/github/callback'
NATIVE_CALLBACK = 'qingqi-installer://github-link'
LIFETIME = 600
SECRET_FORMAT = re.compile(r'[A-Za-z0-9_-]{43}')
SCHEMA = """
CREATE TABLE IF NOT EXISTS developer_github_link (
    account_id TEXT PRIMARY KEY REFERENCES developer_profile(account_id) ON DELETE CASCADE,
    github_id INTEGER NOT NULL UNIQUE,
    login TEXT NOT NULL,
    linked_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS developer_github_flow (
    account_id TEXT PRIMARY KEY REFERENCES developer_profile(account_id) ON DELETE CASCADE,
    state_hash TEXT UNIQUE,
    verifier TEXT,
    receipt_hash TEXT UNIQUE,
    github_id INTEGER,
    login TEXT,
    expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_github_flow_expiry ON developer_github_flow(expires_at);
"""


def _config():
    client_id = os.environ.get('HAPSTORE_GITHUB_OAUTH_CLIENT_ID', '').strip()
    secret = os.environ.get('HAPSTORE_GITHUB_OAUTH_CLIENT_SECRET', '').strip()
    callback = os.environ.get('HAPSTORE_GITHUB_OAUTH_CALLBACK', '').strip()
    try:
        url = urlsplit(callback)
        browser_callback = (url.scheme == 'https' and url.hostname and url.username is None and
                            url.password is None and url.path == CALLBACK and not url.query and not url.fragment)
        if client_id and secret and (callback == NATIVE_CALLBACK or browser_callback):
            return client_id, secret, callback
    except ValueError:
        pass
    return None


def _required_config():
    config = _config()
    if config is None:
        raise registry.RegistryError(503, 'GITHUB_ASSOCIATION_DISABLED', 'GitHub 网页授权尚未配置')
    return config


def _digest(value):
    return sha256(value.encode('ascii')).hexdigest()


def linked(conn, account_id):
    return conn.execute('SELECT github_id,login FROM developer_github_link WHERE account_id=?', (account_id,)).fetchone()


def status(conn, account_id):
    row = linked(conn, account_id)
    return {'enabled': _config() is not None, 'login': row['login'] if row else ''}


def start(conn, account_id):
    client_id, _, callback = _required_config()
    state, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    challenge = base64.urlsafe_b64encode(sha256(verifier.encode()).digest()).decode().rstrip('=')
    now = int(time.time())
    with registry._write(conn):
        if linked(conn, account_id):
            raise registry.RegistryError(409, 'GITHUB_ALREADY_LINKED', '请先解除当前 GitHub 关联')
        conn.execute('INSERT OR IGNORE INTO developer_profile(account_id,enrolled_at) VALUES(?,?)',
                     (account_id, now))
        conn.execute('DELETE FROM developer_github_flow WHERE expires_at<=?', (now,))
        conn.execute("""INSERT OR REPLACE INTO developer_github_flow
            (account_id,state_hash,verifier,expires_at) VALUES (?,?,?,?)""",
            (account_id, _digest(state), verifier, now + LIFETIME))
    params = {'client_id': client_id, 'redirect_uri': callback, 'state': state,
              'code_challenge': challenge, 'code_challenge_method': 'S256'}
    return {'authorization_url': 'https://github.com/login/oauth/authorize?' + urlencode(params)}


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _github_user(config, code, verifier):
    client_id, secret, callback = config
    data = urlencode(dict(client_id=client_id, client_secret=secret, code=code,
                          redirect_uri=callback, code_verifier=verifier)).encode()
    request = Request('https://github.com/login/oauth/access_token', data=data,
                      headers={'Accept': 'application/json', 'User-Agent': 'QSStore-developer-verification'})
    try:
        with build_opener(_RejectRedirect()).open(request, timeout=6) as reply:
            raw = reply.read(16385)
        response = json.loads(raw) if len(raw) <= 16384 else None
        token = response.get('access_token') if isinstance(response, dict) else None
        if not isinstance(token, str) or not 1 <= len(token) <= 2048 or '\r' in token or '\n' in token:
            raise ValueError('Missing GitHub access token')
        user = registry._github('/user', token)
    except (OSError, URLError, ValueError) as error:
        raise registry.RegistryError(502, 'GITHUB_AUTH_FAILED', 'GitHub 授权暂时无法完成，请重新关联') from error
    github_id = user.get('id') if isinstance(user, dict) else None
    login = user.get('login') if isinstance(user, dict) else None
    if (type(github_id) is not int or not 0 < github_id < 2**63 or not isinstance(login, str) or
            not re.fullmatch(r'[A-Za-z0-9-]{1,100}', login)):
        raise registry.RegistryError(502, 'GITHUB_AUTH_FAILED', 'GitHub 未返回可验证的账号')
    # The access and refresh tokens never leave this request or touch storage.
    return github_id, login


def _take_flow(conn, state, code, account_id=None):
    if not isinstance(state, str) or not SECRET_FORMAT.fullmatch(state):
        raise registry.RegistryError(400, 'GITHUB_STATE_INVALID', '授权链接已失效，请从安装器重新打开')
    now = int(time.time())
    flow_hash = _digest(state)
    with registry._write(conn):
        row = conn.execute("""SELECT account_id,verifier,expires_at FROM developer_github_flow
            WHERE state_hash=? AND verifier IS NOT NULL AND expires_at>?""", (flow_hash, now)).fetchone()
        if not row or account_id is not None and row['account_id'] != account_id:
            raise registry.RegistryError(400, 'GITHUB_STATE_INVALID', '授权链接已失效，请从安装器重新打开')
        conn.execute('UPDATE developer_github_flow SET verifier=NULL WHERE state_hash=?', (flow_hash,))
    if not isinstance(code, str) or not code or len(code) > 1024:
        raise registry.RegistryError(400, 'GITHUB_AUTH_CANCELLED', 'GitHub 授权已取消，请返回安装器')
    return flow_hash, row


def complete_browser(conn, state, code):
    config = _required_config()
    if config[2] == NATIVE_CALLBACK:
        raise registry.RegistryError(400, 'GITHUB_STATE_INVALID', '授权后请返回安装器')
    flow_hash, row = _take_flow(conn, state, code)
    github_id, login = _github_user(config, code, row['verifier'])
    receipt = secrets.token_urlsafe(32)
    with registry._write(conn):
        result = conn.execute("""UPDATE developer_github_flow
            SET state_hash=NULL,receipt_hash=?,github_id=?,login=?
            WHERE state_hash=? AND account_id=? AND expires_at>?""",
            (_digest(receipt), github_id, login, flow_hash, row['account_id'], int(time.time())))
        if result.rowcount != 1:
            raise registry.RegistryError(400, 'GITHUB_STATE_INVALID', '授权链接已失效，请从安装器重新打开')
    return receipt


def _bind(conn, account_id, github_id, login):
    other = conn.execute('SELECT 1 FROM developer_github_link WHERE github_id=? AND account_id<>?',
                         (github_id, account_id)).fetchone()
    if other or linked(conn, account_id):
        raise registry.RegistryError(409, 'GITHUB_ALREADY_LINKED', '当前 GitHub 或华为账号已有绑定')
    conn.execute('INSERT INTO developer_github_link VALUES (?,?,?,?)',
                 (account_id, github_id, login, int(time.time())))
    conn.execute('DELETE FROM developer_github_flow WHERE account_id=?', (account_id,))


def complete_native(conn, account_id, state, code):
    config = _required_config()
    if config[2] != NATIVE_CALLBACK:
        raise registry.RegistryError(400, 'GITHUB_STATE_INVALID', '请使用注册的 GitHub 回调地址')
    flow_hash, row = _take_flow(conn, state, code, account_id)
    github_id, login = _github_user(config, code, row['verifier'])
    with registry._write(conn):
        active = conn.execute("""SELECT 1 FROM developer_github_flow
            WHERE state_hash=? AND account_id=? AND expires_at>?""",
            (flow_hash, account_id, int(time.time()))).fetchone()
        if not active:
            raise registry.RegistryError(409, 'GITHUB_STATE_INVALID', '授权链接已失效，请从安装器重新打开')
        _bind(conn, account_id, github_id, login)
    return status(conn, account_id)


def confirm(conn, account_id, receipt):
    if not isinstance(receipt, str) or not SECRET_FORMAT.fullmatch(receipt):
        raise registry.RegistryError(400, 'GITHUB_RECEIPT_INVALID', '授权回执无效，请重新关联')
    with registry._write(conn):
        row = conn.execute("""SELECT github_id,login FROM developer_github_flow
            WHERE account_id=? AND receipt_hash=? AND expires_at>?""",
            (account_id, _digest(receipt), int(time.time()))).fetchone()
        if not row:
            raise registry.RegistryError(409, 'GITHUB_RECEIPT_INVALID', '请在发起授权的安装器账号中完成关联')
        _bind(conn, account_id, row['github_id'], row['login'])
    return status(conn, account_id)


def unlink(conn, account_id):
    with registry._write(conn):
        for table in ('developer_github_link', 'developer_github_flow'):
            conn.execute(f'DELETE FROM {table} WHERE account_id=?', (account_id,))
    return status(conn, account_id)


def claim(conn, app_id, account_id, collector_token, nickname):
    linked_user = linked(conn, account_id)
    if not linked_user:
        raise registry.RegistryError(409, 'GITHUB_LINK_REQUIRED', '请先关联 GitHub 账号')
    return registry.claim_as_github_owner(conn, app_id, account_id, linked_user['github_id'], collector_token,
                                         nickname or linked_user['login'])
