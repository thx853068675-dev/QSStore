"""Verified repository identities used by the listing entry points."""
from __future__ import annotations

import re
import time


def resolve(repo: str, *, token: str = '') -> dict:
    from . import collector
    if not repo.startswith('gitee.com/'):
        remote_id, canonical = collector.github_repository_identity(repo, token=token)
        return dict(provider='github', remote_id=remote_id, canonical_repo=canonical)
    data = collector._repository_json(repo, timeout=5)
    # Gitee's full_name may contain a display name; html_url has the URL path.
    canonical = collector.normalize_repo(data.get('html_url', '')) if isinstance(data, dict) else None
    if (not isinstance(data, dict) or data.get('private') is not False or
            type(data.get('id')) is not int or data['id'] <= 0 or
            not isinstance(canonical, str) or
            not re.fullmatch(r'gitee\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', canonical)):
        raise collector.CollectError('无法核验公开的 Gitee 仓库')
    return dict(provider='gitee', remote_id=data['id'], canonical_repo=canonical)


def validate(identity: dict) -> None:
    canonical = identity.get('canonical_repo', '')
    path = canonical.removeprefix('gitee.com/') if isinstance(canonical, str) else ''
    if (identity.get('provider') not in ('github', 'gitee') or
            type(identity.get('remote_id')) is not int or identity['remote_id'] <= 0 or
            not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', path) or
            (identity['provider'] == 'gitee') != canonical.startswith('gitee.com/')):
        raise ValueError('REPOSITORY_IDENTITY_REQUIRED')


def same(left: dict, right: dict) -> bool:
    return (left.get('provider'), left.get('remote_id')) == (right.get('provider'), right.get('remote_id'))


def existing(c, repo: str, identity: dict, account_id: str):
    validate(identity)
    rows = c.execute("""SELECT a.*,p.account_id AS publisher_account_id,
            i.provider AS identity_provider,i.remote_id AS identity_remote_id
        FROM app a LEFT JOIN publisher p ON p.app_id=a.id
        LEFT JOIN app_repository_identity i ON i.app_id=a.id
        WHERE (i.provider=? AND i.remote_id=?) OR
            a.repo_full_name=? COLLATE NOCASE OR a.repo_full_name=? COLLATE NOCASE
        ORDER BY a.id""",
        (identity['provider'], identity['remote_id'], repo, identity['canonical_repo'])).fetchall()
    # An old URL can be reused by a different repository. It cannot take over
    # the previous listing, including when the original listing was hidden.
    for row in rows:
        if row['identity_provider'] and (
            row['identity_provider'], row['identity_remote_id']
        ) != (identity['provider'], identity['remote_id']):
            raise ValueError('REPOSITORY_CHANGED')
    published = [row for row in rows if row['status'] == 'published']
    owned = [row for row in published if row['publisher_account_id'] == account_id]
    foreign = [row for row in published if row['publisher_account_id'] and
               row['publisher_account_id'] != account_id]
    candidates = owned or foreign or published or rows
    return next((row for row in candidates if row['repo_full_name'].lower() == repo.lower()),
                candidates[0] if candidates else None)


def bind(c, app_id: int, identity: dict) -> None:
    validate(identity)
    previous = c.execute('SELECT * FROM app_repository_identity WHERE app_id=?', (app_id,)).fetchone()
    if previous and not same(dict(previous), identity):
        raise ValueError('REPOSITORY_CHANGED')
    c.execute("""INSERT INTO app_repository_identity(app_id,provider,remote_id,canonical_repo,verified_at)
        VALUES (?,?,?,?,?) ON CONFLICT(app_id) DO UPDATE SET
            canonical_repo=excluded.canonical_repo,verified_at=excluded.verified_at""",
        (app_id, identity['provider'], identity['remote_id'], identity['canonical_repo'], int(time.time())))
