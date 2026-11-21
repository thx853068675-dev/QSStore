"""Self-service developer enrollment and verification of public GitHub listings."""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime
import json
import re
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from . import submission_repository

SLUG = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+')
SCHEMA = """
CREATE TABLE IF NOT EXISTS developer_profile (
    account_id TEXT PRIMARY KEY,
    enrolled_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS developer_claim (
    app_id INTEGER PRIMARY KEY REFERENCES app(id) ON DELETE CASCADE,
    repository_id INTEGER NOT NULL UNIQUE,
    account_id TEXT NOT NULL REFERENCES developer_profile(account_id),
    claimed_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_developer_claim_account ON developer_claim(account_id);
CREATE TABLE IF NOT EXISTS developer_review_hidden (
    review_id INTEGER PRIMARY KEY REFERENCES review(id) ON DELETE CASCADE,
    hidden_at INTEGER NOT NULL
);
"""

REPOSITORY_JOIN = """JOIN app_repository_identity i ON i.app_id=d.app_id
                     AND i.provider='github' AND i.remote_id=d.repository_id"""
OWNER_JOIN = REPOSITORY_JOIN + " JOIN app a ON a.id=d.app_id AND a.status='published'"


class RegistryError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code


class _GitHubRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).netloc != 'api.github.com' or urlsplit(newurl).scheme != 'https':
            raise RegistryError(502, 'GITHUB_UNAVAILABLE', '暂时无法连接 GitHub，请稍后重试')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _github(path: str, token: str, *, missing: bool = False):
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'QSStore-developer-verification'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    try:
        with build_opener(_GitHubRedirect()).open(Request('https://api.github.com' + path, headers=headers),
                                                  timeout=5) as response:
            raw = response.read(384 * 1024 + 1)
        if len(raw) > 384 * 1024:
            raise ValueError('Response size')
        return json.loads(raw)
    except HTTPError as error:
        if error.code == 404:
            if missing:
                return None
            raise RegistryError(422, 'REPOSITORY_UNAVAILABLE', 'GitHub 公开仓库不存在或不可读') from error
        raise RegistryError(502, 'GITHUB_UNAVAILABLE', '暂时无法连接 GitHub，请稍后重试') from error
    except (URLError, OSError, ValueError) as error:
        raise RegistryError(502, 'GITHUB_UNAVAILABLE', '暂时无法连接 GitHub，请稍后重试') from error


def _slug(value) -> bool:
    return isinstance(value, str) and bool(SLUG.fullmatch(value)) and not {'.', '..'}.intersection(value.split('/'))


def _repository(repo: str, token: str) -> dict:
    if not _slug(repo):
        raise RegistryError(422, 'REPOSITORY_UNSUPPORTED', '当前仅支持认领公开 GitHub 仓库')
    data = _github('/repos/' + repo, token)
    if (not isinstance(data, dict) or data.get('private') is not False or
            type(data.get('id')) is not int or not 0 < data['id'] < 2**63 or
            not _slug(data.get('full_name')) or data.get('disabled')):
        raise RegistryError(422, 'REPOSITORY_UNAVAILABLE', '请使用 GitHub 公开仓库')
    return data


def _listing(conn, app_id):
    row = conn.execute("""SELECT a.id,a.repo_full_name AS repo,a.created_at,
        i.provider,i.remote_id FROM app a LEFT JOIN app_repository_identity i ON i.app_id=a.id
        WHERE a.id=? AND a.status='published'""", (app_id,)).fetchone()
    if row is None:
        raise RegistryError(404, 'APP_NOT_FOUND', '应用不存在')
    return row


def _check_repo(listing, remote):
    if listing['provider'] is not None:
        if (listing['provider'], listing['remote_id']) == ('github', remote['id']):
            return
    else:
        # Legacy listings predate numeric binding. A recycled URL must not verify a newer repository.
        try:
            created = datetime.fromisoformat(remote['created_at'].replace('Z', '+00:00'))
            if created.tzinfo is not None and created.timestamp() <= listing['created_at']:
                return
        except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
            pass
    raise RegistryError(409, 'REPOSITORY_CHANGED', '商店记录与当前仓库不一致，请联系管理员')


@contextmanager
def _write(conn):
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        yield


def enrolled(conn, account_id):
    return conn.execute('SELECT 1 FROM developer_profile WHERE account_id=?', (account_id,)).fetchone() is not None


def enroll(conn, account_id):
    with conn:
        conn.execute('INSERT OR IGNORE INTO developer_profile(account_id,enrolled_at) VALUES (?,?)',
                     (account_id, int(time.time())))
    return center(conn, account_id)


def owns(conn, app_id, account_id):
    return bool(account_id and conn.execute(f"""SELECT 1 FROM developer_claim d {OWNER_JOIN}
        WHERE d.app_id=? AND d.account_id=?""", (app_id, account_id)).fetchone())


def moderates(conn, app_id, account_id):
    return bool(account_id and (owns(conn, app_id, account_id) or conn.execute('''SELECT 1
        FROM publisher p JOIN app a ON a.id=p.app_id AND a.status='published'
        WHERE p.app_id=? AND p.account_id=?''', (app_id, account_id)).fetchone()))


def claimant(conn, app_id):
    row = conn.execute(f"""SELECT d.account_id FROM developer_claim d {REPOSITORY_JOIN}
        WHERE d.app_id=?""", (app_id,)).fetchone()
    return row['account_id'] if row else None


def migrate_claimed_publishers(conn):
    with conn:
        conn.execute(f"""INSERT INTO publisher(app_id,account_id,display_name,updated_at)
            SELECT d.app_id,d.account_id,COALESCE(NULLIF(g.login,''),'开发者'),d.claimed_at
            FROM developer_claim d {REPOSITORY_JOIN}
            LEFT JOIN developer_github_link g ON g.account_id=d.account_id WHERE 1
            ON CONFLICT(app_id) DO UPDATE SET account_id=excluded.account_id,
                display_name=excluded.display_name,updated_at=excluded.updated_at
            WHERE publisher.account_id<>excluded.account_id""")


def center(conn, account_id):
    rows = conn.execute(f"""SELECT d.app_id,COALESCE(NULLIF(a.display_name,''),a.name) AS name,
        i.canonical_repo AS repo,d.claimed_at FROM developer_claim d {OWNER_JOIN}
        WHERE d.account_id=? ORDER BY d.claimed_at DESC,d.app_id DESC""", (account_id,))
    return {'enrolled': enrolled(conn, account_id), 'items': [dict(row) for row in rows]}


def _claim(conn, listing, repository_id=None):
    return conn.execute('SELECT app_id,account_id FROM developer_claim WHERE app_id=? OR repository_id=?',
                        (listing['id'], repository_id or listing['remote_id'])).fetchone()


def status(conn, app_id, account_id):
    row = _listing(conn, app_id)
    if not _slug(row['repo']) or row['provider'] == 'gitee':
        return {'status': 'unsupported'}
    claim = _claim(conn, row)
    if claim:
        return {'status': 'mine' if claim['app_id'] == app_id and claim['account_id'] == account_id else 'claimed'}
    return {'status': 'available', 'enrolled': enrolled(conn, account_id)}


def _require_enrollment(conn, account_id):
    if not enrolled(conn, account_id):
        raise RegistryError(409, 'DEVELOPER_ENROLLMENT_REQUIRED', '请先开通开发者中心')


def _require_available(conn, row, account_id, repository_id=None):
    claim = _claim(conn, row, repository_id)
    if claim and not (claim['account_id'] == account_id and claim['app_id'] == row['id']):
        raise RegistryError(409, 'APP_ALREADY_CLAIMED', '该仓库已有认领开发者')


def _require_unchanged(previous, current):
    if previous['repo'].lower() != current['repo'].lower():
        raise RegistryError(409, 'REPOSITORY_CHANGED', '仓库地址已更新，请重新认领')


def _record_claim(conn, app_id, account_id, remote, display_name):
    submission_repository.bind(conn, app_id, dict(provider='github', remote_id=remote['id'],
                                                  canonical_repo=remote['full_name']))
    now = int(time.time())
    conn.execute('INSERT INTO developer_claim VALUES (?,?,?,?)', (app_id, remote['id'], account_id, now))
    conn.execute("""INSERT INTO publisher(app_id,account_id,display_name,updated_at) VALUES (?,?,?,?)
        ON CONFLICT(app_id) DO UPDATE SET account_id=excluded.account_id,
            display_name=excluded.display_name,updated_at=excluded.updated_at""",
        (app_id, account_id, display_name[:100], now))


def claim_as_github_owner(conn, app_id, account_id, github_id, token, display_name):
    _require_enrollment(conn, account_id)
    row = _listing(conn, app_id)
    if owns(conn, app_id, account_id):
        return {'status': 'mine'}
    _require_available(conn, row, account_id)
    remote = _repository(row['repo'], token)
    owner = remote.get('owner')
    if (not isinstance(owner, dict) or owner.get('type') != 'User' or
            type(owner.get('id')) is not int or owner['id'] != github_id):
        raise RegistryError(403, 'GITHUB_REPOSITORY_NOT_OWNED',
                            '请使用此公开仓库的所有者账号关联 GitHub')
    with _write(conn):
        current = _listing(conn, app_id)
        _require_unchanged(row, current)
        _check_repo(current, remote)
        _require_available(conn, current, account_id, remote['id'])
        if not conn.execute('SELECT 1 FROM developer_github_link WHERE account_id=? AND github_id=?',
                            (account_id, github_id)).fetchone():
            raise RegistryError(409, 'GITHUB_LINK_REQUIRED', '请先关联 GitHub 账号')
        if not owns(conn, app_id, account_id):
            _record_claim(conn, app_id, account_id, remote, display_name)
    return {'status': 'mine'}


def release(conn, app_id, account_id):
    with _write(conn):
        conn.execute('DELETE FROM developer_claim WHERE app_id=? AND account_id=?', (app_id, account_id))
    return center(conn, account_id)


def moderate(conn, app_id, review_id, account_id, hidden):
    with _write(conn):
        if not moderates(conn, app_id, account_id):
            raise RegistryError(403, 'MODERATION_REQUIRED', '仅应用上架者或已认领的开发者可以管理评论')
        if not conn.execute('SELECT 1 FROM review WHERE id=? AND app_id=?', (review_id, app_id)).fetchone():
            raise RegistryError(404, 'REVIEW_NOT_FOUND', '评论不存在')
        if hidden:
            conn.execute('INSERT OR IGNORE INTO developer_review_hidden VALUES (?,?)', (review_id, int(time.time())))
        else:
            conn.execute('DELETE FROM developer_review_hidden WHERE review_id=?', (review_id,))
