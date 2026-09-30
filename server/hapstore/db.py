#!/usr/bin/env python3
# Copyright QuietStart contributors. SPDX-License-Identifier: MIT
"""HAP 商店元数据服务 —— 数据层。

设计约束（很重要）：
  · 本服务只用 Python 标准库（sqlite3 / http.server / urllib）
  · 只存索引，**不存 HAP 文件本体** —— 主包在客户端直接向 GitHub/镜像下载

线程模型：http.server.ThreadingHTTPServer 每个请求一个线程，
SQLite 连接用 thread-local 持有，写入统一走短事务 + WAL。
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import threading
import time
from typing import Any, Iterable

DB_PATH = os.environ.get("HAPSTORE_DB", "/var/lib/hapstore/hapstore.db")

SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS app (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_full_name TEXT NOT NULL UNIQUE,          -- owner/repo
    owner         TEXT NOT NULL,
    name          TEXT NOT NULL,
    display_name  TEXT NOT NULL DEFAULT '',
    summary       TEXT NOT NULL DEFAULT '',
    description   TEXT NOT NULL DEFAULT '',
    icon_url      TEXT NOT NULL DEFAULT '',
    category      TEXT NOT NULL DEFAULT '其他',
    tags_json     TEXT NOT NULL DEFAULT '[]',
    stars         INTEGER NOT NULL DEFAULT 0,
    license       TEXT NOT NULL DEFAULT '',
    homepage      TEXT NOT NULL DEFAULT '',
    verified      INTEGER NOT NULL DEFAULT 0,     -- 仓库归属已验证
    status        TEXT NOT NULL DEFAULT 'published',  -- published|hidden
    featured      INTEGER NOT NULL DEFAULT 0,     -- 是否进「今日」精选
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    synced_at     INTEGER NOT NULL DEFAULT 0,
    sync_error    TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS app_icon (
    app_id INTEGER PRIMARY KEY REFERENCES app(id) ON DELETE CASCADE,
    mime TEXT NOT NULL,
    data BLOB NOT NULL,
    digest TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS publisher (
    app_id INTEGER PRIMARY KEY REFERENCES app(id) ON DELETE CASCADE,
    account_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS review (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id INTEGER NOT NULL REFERENCES app(id) ON DELETE CASCADE,
    account_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    stars INTEGER NOT NULL CHECK(stars BETWEEN 1 AND 5),
    body TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS account_avatar (
    account_id TEXT PRIMARY KEY,
    avatar_url TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS signing_identity (
    account_id TEXT PRIMARY KEY,
    cert_id TEXT NOT NULL,
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1
);


CREATE TABLE IF NOT EXISTS release (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id        INTEGER NOT NULL REFERENCES app(id) ON DELETE CASCADE,
    tag           TEXT NOT NULL,
    name          TEXT NOT NULL DEFAULT '',
    body          TEXT NOT NULL DEFAULT '',
    published_at  TEXT NOT NULL DEFAULT '',
    prerelease    INTEGER NOT NULL DEFAULT 0,
    html_url      TEXT NOT NULL DEFAULT '',
    etag          TEXT NOT NULL DEFAULT '',
    fetched_at    INTEGER NOT NULL DEFAULT 0,
    UNIQUE(app_id, tag)
);

CREATE TABLE IF NOT EXISTS asset (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    release_id    INTEGER NOT NULL REFERENCES release(id) ON DELETE CASCADE,
    name          TEXT NOT NULL,
    size          INTEGER NOT NULL DEFAULT 0,
    sha256        TEXT NOT NULL DEFAULT '',
    download_url  TEXT NOT NULL DEFAULT '',
    bundle_name   TEXT NOT NULL DEFAULT '',
    version_code  INTEGER NOT NULL DEFAULT 0,
    version_name  TEXT NOT NULL DEFAULT '',
    min_api       INTEGER NOT NULL DEFAULT 0,
    UNIQUE(release_id, name)
);

CREATE TABLE IF NOT EXISTS submit_task (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_url      TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'pending',  -- pending|ok|failed
    result_json   TEXT NOT NULL DEFAULT '{}',
    ip_hash       TEXT NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS submit_draft (
    token TEXT PRIMARY KEY,
    repo TEXT NOT NULL,
    account_id TEXT NOT NULL,
    choices_json TEXT NOT NULL,
    suggested_category TEXT NOT NULL,
    prepared_json TEXT NOT NULL DEFAULT '{}',
    expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS app_selection (
    app_id INTEGER PRIMARY KEY REFERENCES app(id) ON DELETE CASCADE,
    asset_name TEXT NOT NULL,
    bundle_name TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS app_category (
    app_id INTEGER PRIMARY KEY REFERENCES app(id) ON DELETE CASCADE,
    category TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS report (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id        INTEGER NOT NULL REFERENCES app(id) ON DELETE CASCADE,
    reason        TEXT NOT NULL,
    detail        TEXT NOT NULL DEFAULT '',
    ip_hash       TEXT NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS event_download (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id        INTEGER NOT NULL,
    asset_id      INTEGER NOT NULL,
    device_hash   TEXT NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS meta (
    k TEXT PRIMARY KEY,
    v TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_release_app ON release(app_id, published_at DESC);
CREATE INDEX IF NOT EXISTS idx_asset_release ON asset(release_id);
CREATE INDEX IF NOT EXISTS idx_app_status ON app(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_event_app ON event_download(app_id, created_at);
CREATE INDEX IF NOT EXISTS idx_review_app ON review(app_id, updated_at DESC);
"""

_local = threading.local()
_init_lock = threading.Lock()
_initialized = False


def connect() -> sqlite3.Connection:
    """取得本线程的连接。"""
    conn = getattr(_local, "conn", None)
    if conn is None:
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        conn = sqlite3.connect(DB_PATH, timeout=15.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        _local.conn = conn
    return conn


def init_db() -> None:
    global _initialized
    with _init_lock:
        if _initialized:
            return
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        conn = connect()
        conn.executescript(SCHEMA)
        if 'prepared_json' not in {row['name'] for row in conn.execute('PRAGMA table_info(submit_draft)')}:
            conn.execute("ALTER TABLE submit_draft ADD COLUMN prepared_json TEXT NOT NULL DEFAULT '{}'")
        if 'digest' not in {row['name'] for row in conn.execute('PRAGMA table_info(app_icon)')}:
            conn.execute("ALTER TABLE app_icon ADD COLUMN digest TEXT NOT NULL DEFAULT ''")
        for row in list(conn.execute("SELECT app_id,data FROM app_icon WHERE digest=''")):
            conn.execute("UPDATE app_icon SET digest=? WHERE app_id=?",
                         (hashlib.sha256(row['data']).hexdigest()[:16], row['app_id']))
        if 'revision' not in {row['name'] for row in conn.execute(
            'PRAGMA table_info(signing_identity)'
        )}:
            conn.execute('ALTER TABLE signing_identity ADD COLUMN revision INTEGER NOT NULL DEFAULT 1')
        # SQLite cannot drop a table-level UNIQUE constraint in place. Preserve
        # existing comments while changing the model to one row per submission.
        review_sql = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='review'"
        ).fetchone()["sql"]
        if "UNIQUE(APP_ID, ACCOUNT_ID)" in review_sql.upper():
            conn.execute("ALTER TABLE review RENAME TO review_single_comment")
            conn.execute("""CREATE TABLE review (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id INTEGER NOT NULL REFERENCES app(id) ON DELETE CASCADE,
                account_id TEXT NOT NULL,
                display_name TEXT NOT NULL,
                stars INTEGER NOT NULL CHECK(stars BETWEEN 1 AND 5),
                body TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )""")
            conn.execute("""INSERT INTO review
                (id,app_id,account_id,display_name,stars,body,created_at,updated_at)
                SELECT id,app_id,account_id,display_name,stars,body,created_at,updated_at
                FROM review_single_comment""")
            conn.execute("DROP TABLE review_single_comment")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_review_app ON review(app_id, updated_at DESC)")
        conn.commit()
        _initialized = True


# ────────────────────────────── 查询 ──────────────────────────────


def _row_to_app(row: sqlite3.Row, *, with_counts: bool = True) -> dict[str, Any]:
    icon = connect().execute("SELECT digest FROM app_icon WHERE app_id=?", (row['id'],)).fetchone()
    app = {
        "id": row["id"],
        "repo": row["repo_full_name"],
        "owner": row["owner"],
        "name": row["name"],
        "display_name": row["display_name"] or row["name"],
        "summary": row["summary"],
        "description": row["description"],
        "icon_url": f"/api/v1/apps/{row['id']}/icon" if icon else "",
        "icon_rev": icon['digest'] if icon else "",
        "category": row["category"],
        "tags": json.loads(row["tags_json"] or "[]"),
        "stars": row["stars"],
        "license": row["license"],
        "homepage": row["homepage"],
        "verified": bool(row["verified"]),
        "status": row["status"],
        "featured": bool(row["featured"]),
        "updated_at": row["updated_at"],
        "synced_at": row["synced_at"],
        "sync_error": row["sync_error"],
    }
    publisher = connect().execute(
        "SELECT display_name FROM publisher WHERE app_id=?", (row["id"],)
    ).fetchone()
    app["publisher_name"] = publisher["display_name"] if publisher else ""
    if with_counts:
        c = connect()
        n = c.execute(
            "SELECT COUNT(*) AS n FROM release WHERE app_id=? AND prerelease=0", (row["id"],)
        ).fetchone()["n"]
        latest = c.execute(
            """SELECT tag, name, published_at, prerelease FROM release
               WHERE app_id=? AND prerelease=0 ORDER BY published_at DESC LIMIT 1""",
            (row["id"],),
        ).fetchone()
        app["releases_count"] = n
        app["latest"] = dict(latest) if latest else None
        app["latest_asset"] = latest_asset(c, row["id"])
    return app


def latest_asset(c: sqlite3.Connection, app_id: int) -> dict[str, Any] | None:
    """最新版本里最大的 HAP 附件。

    客户端需要 bundleName / versionCode / sha256 才能判断「装没装」并直接安装。
    没有这个字段时它得为目录里每个应用单独请求一次 releases —— 每请求一次
    服务端往返约 1 秒，一屏 30 个应用就是半分钟。
    取最大的附件与客户端选择默认版本的规则一致。
    """
    row = c.execute(
        """SELECT a.* FROM asset a JOIN release r ON r.id = a.release_id
           WHERE r.app_id=? AND r.prerelease=0 AND a.bundle_name <> ''
           ORDER BY r.published_at DESC, a.size DESC LIMIT 1""",
        (app_id,),
    ).fetchone()
    return _row_to_asset(row) if row else None


def list_apps(
    *,
    q: str = "",
    category: str = "",
    sort: str = "updated",
    featured: bool | None = None,
    page: int = 1,
    page_size: int = 30,
) -> dict[str, Any]:
    c = connect()
    where = ["status='published'"]
    params: list[Any] = []
    if q:
        where.append("(display_name LIKE ? OR name LIKE ? OR repo_full_name LIKE ? OR summary LIKE ?)")
        like = f"%{q}%"
        params += [like, like, like, like]
    if category:
        where.append("category=?")
        params.append(category)
    if featured is not None:
        where.append("featured=?")
        params.append(1 if featured else 0)

    order = {
        "updated": "updated_at DESC",
        "stars": "stars DESC",
        "name": "display_name COLLATE NOCASE ASC",
        "new": "created_at DESC",
    }.get(sort, "updated_at DESC")

    clause = " AND ".join(where)
    total = c.execute(f"SELECT COUNT(*) AS n FROM app WHERE {clause}", params).fetchone()["n"]
    page = max(1, page)
    page_size = max(1, min(100, page_size))
    offset = (page - 1) * page_size
    rows = c.execute(
        f"SELECT * FROM app WHERE {clause} ORDER BY {order} LIMIT ? OFFSET ?",
        params + [page_size, offset],
    ).fetchall()
    return {
        "items": [_row_to_app(r) for r in rows],
        "total": total,
        "page": page,
        "page_size": page_size,
    }


def get_app(app_id: int) -> dict[str, Any] | None:
    row = connect().execute("SELECT * FROM app WHERE id=?", (app_id,)).fetchone()
    return _row_to_app(row) if row else None


def get_app_by_repo(repo: str) -> dict[str, Any] | None:
    row = connect().execute(
        "SELECT * FROM app WHERE repo_full_name=?", (repo,)
    ).fetchone()
    return _row_to_app(row) if row else None


def list_published_by_account(account_id: str) -> list[dict[str, Any]]:
    rows = connect().execute(
        """SELECT app.* FROM app JOIN publisher ON publisher.app_id=app.id
           WHERE publisher.account_id=? AND app.status='published'
           ORDER BY app.updated_at DESC, app.id DESC""", (account_id,)
    ).fetchall()
    return [_row_to_app(row) for row in rows]


def hide_published_app(app_id: int, account_id: str) -> bool:
    """Remove a listing from public view while retaining its history for re-listing."""
    c = connect()
    cur = c.execute(
        """UPDATE app SET status='hidden', featured=0, updated_at=?
           WHERE id=? AND status='published' AND EXISTS (
             SELECT 1 FROM publisher WHERE publisher.app_id=app.id
             AND publisher.account_id=?)""", (int(time.time()), app_id, account_id)
    )
    c.commit()
    return cur.rowcount == 1


def set_app_category(app_id: int, category: str) -> None:
    """用户选定的分类保留在独立表中，不被 GitHub 自动分类覆盖。"""
    c = connect()
    c.execute("INSERT OR REPLACE INTO app_category (app_id,category) VALUES (?,?)",
              (app_id, category))
    c.execute("UPDATE app SET category=?, updated_at=? WHERE id=?",
              (category, int(time.time()), app_id))
    c.commit()


def get_app_category(app_id: int) -> str:
    row = connect().execute("SELECT category FROM app_category WHERE app_id=?", (app_id,)).fetchone()
    return row["category"] if row else ""


def configure_published_app(app_id: int, account_id: str, category: str) -> bool:
    c = connect()
    with c:
        cur = c.execute(
            """UPDATE app SET category=?, updated_at=? WHERE id=? AND status='published'
               AND EXISTS (SELECT 1 FROM publisher WHERE publisher.app_id=app.id
               AND publisher.account_id=?)""", (category, int(time.time()), app_id, account_id))
        if cur.rowcount != 1:
            return False
        c.execute("INSERT OR REPLACE INTO app_category (app_id,category) VALUES (?,?)",
                  (app_id, category))
    return True


def list_releases(app_id: int, *, page: int = 1, page_size: int = 20,
                  include_prerelease: bool = False) -> dict[str, Any]:
    c = connect()
    where = ["app_id=?"]
    params: list[Any] = [app_id]
    if not include_prerelease:
        where.append("prerelease=0")
    clause = " AND ".join(where)

    total = c.execute(f"SELECT COUNT(*) AS n FROM release WHERE {clause}", params).fetchone()["n"]
    page = max(1, page)
    page_size = max(1, min(50, page_size))
    rows = c.execute(
        f"""SELECT * FROM release WHERE {clause}
            ORDER BY published_at DESC LIMIT ? OFFSET ?""",
        params + [page_size, (page - 1) * page_size],
    ).fetchall()

    out = []
    for r in rows:
        assets = c.execute(
            "SELECT * FROM asset WHERE release_id=? ORDER BY name", (r["id"],)
        ).fetchall()
        out.append(
            {
                "tag": r["tag"],
                "name": r["name"],
                "body": r["body"],
                "published_at": r["published_at"],
                "prerelease": bool(r["prerelease"]),
                "html_url": r["html_url"],
                "assets": [_row_to_asset(a) for a in assets],
            }
        )
    return {"items": out, "total": total, "page": page, "page_size": page_size}


def _row_to_asset(a: sqlite3.Row) -> dict[str, Any]:
    return {
        "name": a["name"],
        "size": a["size"],
        "sha256": a["sha256"],
        "url": a["download_url"],
        # 客户端据此做多镜像竞速；服务器不中转文件字节
        "mirror_urls": mirror_urls(a["download_url"]),
        "bundle_name": a["bundle_name"],
        "version_code": a["version_code"],
        "version_name": a["version_name"],
        "min_api": a["min_api"],
    }


def get_release(app_id: int, tag: str) -> dict[str, Any] | None:
    c = connect()
    r = c.execute(
        "SELECT * FROM release WHERE app_id=? AND tag=?", (app_id, tag)
    ).fetchone()
    if not r:
        return None
    assets = c.execute(
        "SELECT * FROM asset WHERE release_id=? ORDER BY name", (r["id"],)
    ).fetchall()
    return {
        "tag": r["tag"],
        "name": r["name"],
        "body": r["body"],
        "published_at": r["published_at"],
        "prerelease": bool(r["prerelease"]),
        "html_url": r["html_url"],
        "assets": [_row_to_asset(a) for a in assets],
    }


def get_asset(asset_id: int) -> dict[str, Any] | None:
    row = connect().execute("SELECT * FROM asset WHERE id=?", (asset_id,)).fetchone()
    return _row_to_asset(row) if row else None


def app_icon_url(app_id: int) -> str:
    row = connect().execute("SELECT icon_url FROM app WHERE id=?", (app_id,)).fetchone()
    return row["icon_url"] if row else ""


def app_icon(app_id: int) -> tuple[str, bytes] | None:
    row = connect().execute("SELECT mime, data FROM app_icon WHERE app_id=?", (app_id,)).fetchone()
    return (row["mime"], row["data"]) if row else None


def has_app_icon(app_id: int) -> bool:
    return connect().execute("SELECT 1 FROM app_icon WHERE app_id=?", (app_id,)).fetchone() is not None


def put_app_icon(app_id: int, mime: str, data: bytes) -> None:
    if mime not in ("image/png", "image/jpeg", "image/webp") or not data or len(data) > 1024 * 1024:
        raise ValueError("invalid app icon")
    c = connect()
    c.execute("INSERT OR REPLACE INTO app_icon(app_id,mime,data,digest) VALUES (?,?,?,?)",
              (app_id, mime, data, hashlib.sha256(data).hexdigest()[:16]))
    c.commit()


def delete_app_icon(app_id: int) -> None:
    c = connect()
    c.execute("DELETE FROM app_icon WHERE app_id=?", (app_id,))
    c.commit()


def set_publisher(app_id: int, account_id: str, display_name: str) -> None:
    c = connect()
    c.execute("""INSERT INTO publisher(app_id,account_id,display_name,updated_at)
                 VALUES (?,?,?,?) ON CONFLICT(app_id) DO UPDATE SET
                 display_name=excluded.display_name,updated_at=excluded.updated_at
                 WHERE publisher.account_id=excluded.account_id""",
              (app_id, account_id, display_name[:100], int(time.time())))
    c.commit()


def review_summary(app_id: int) -> dict[str, Any]:
    row = connect().execute(
        "SELECT COUNT(*) AS n, AVG(stars) AS avg FROM review WHERE app_id=?", (app_id,)
    ).fetchone()
    return {"count": row["n"], "average": round(row["avg"] or 0, 1)}


def list_reviews(app_id: int, page: int = 1, page_size: int = 20) -> dict[str, Any]:
    page = max(1, page)
    page_size = max(1, min(50, page_size))
    c = connect()
    total = c.execute("SELECT COUNT(*) AS n FROM review WHERE app_id=?", (app_id,)).fetchone()["n"]
    rows = c.execute(
        """SELECT review.id, review.display_name, review.stars, review.body,
                  review.updated_at, COALESCE(account_avatar.avatar_url, '') AS avatar_url
           FROM review LEFT JOIN account_avatar
             ON account_avatar.account_id = review.account_id
           WHERE review.app_id=? ORDER BY review.updated_at DESC, review.id DESC
           LIMIT ? OFFSET ?""",
        (app_id, page_size, (page - 1) * page_size),
    ).fetchall()
    return {"items": [dict(row) for row in rows], "summary": review_summary(app_id),
            "total": total, "page": page, "page_size": page_size}


def put_review(app_id: int, account_id: str, display_name: str, stars: int, body: str) -> None:
    now = int(time.time())
    c = connect()
    c.execute("""INSERT INTO review(app_id,account_id,display_name,stars,body,created_at,updated_at)
                 VALUES (?,?,?,?,?,?,?)""",
              (app_id, account_id, display_name[:100], stars, body[:2000], now, now))
    c.commit()


def set_account_avatar(account_id: str, avatar_url: str) -> None:
    """Keep the last avatar verified through Huawei's profile response."""
    if not avatar_url:
        return
    c = connect()
    c.execute("""INSERT INTO account_avatar(account_id,avatar_url,updated_at)
                 VALUES (?,?,?) ON CONFLICT(account_id) DO UPDATE SET
                 avatar_url=excluded.avatar_url, updated_at=excluded.updated_at""",
              (account_id, avatar_url, int(time.time())))
    c.commit()


def update_account_display_name(account_id: str, display_name: str) -> None:
    """Refresh older publisher/review rows after a verified sign-in."""
    # A temporary GOpen failure falls back to the account ID. Keep the last
    # verified public nickname in rows that already have one.
    if not display_name or display_name == account_id:
        return
    c = connect()
    c.execute("UPDATE publisher SET display_name=? WHERE account_id=?",
              (display_name[:100], account_id))
    c.execute("UPDATE review SET display_name=? WHERE account_id=?",
              (display_name[:100], account_id))
    c.commit()


def create_submit_draft(token: str, repo: str, account_id: str,
                        choices: list[dict[str, Any]], category: str,
                        prepared: dict[str, Any] | None = None) -> None:
    c = connect()
    c.execute("DELETE FROM submit_draft WHERE expires_at<?", (int(time.time()),))
    c.execute("""INSERT INTO submit_draft
              (token,repo,account_id,choices_json,suggested_category,prepared_json,expires_at)
              VALUES (?,?,?,?,?,?,?)""",
              (token, repo, account_id, json.dumps(choices, ensure_ascii=False),
               category, json.dumps(prepared or {}, ensure_ascii=False), int(time.time()) + 1800))
    c.commit()


def recent_submit_draft(repo: str, account_id: str) -> dict[str, Any] | None:
    row = connect().execute("""SELECT prepared_json,expires_at FROM submit_draft
        WHERE repo=? COLLATE NOCASE AND account_id=? AND expires_at>?
          AND prepared_json!='{}' ORDER BY expires_at DESC LIMIT 1""",
        (repo, account_id, int(time.time()) + 1500)).fetchone()
    if not row:
        return None
    return {"prepared": json.loads(row["prepared_json"]), "expires_at": row["expires_at"]}


def get_submit_draft(token: str, account_id: str) -> dict[str, Any] | None:
    row = connect().execute("""SELECT * FROM submit_draft
        WHERE token=? AND account_id=? AND expires_at>=?""",
        (token, account_id, int(time.time()))).fetchone()
    if not row:
        return None
    out = dict(row)
    out["choices"] = json.loads(out.pop("choices_json"))
    return out


def finish_submit_draft(token: str) -> None:
    c = connect()
    c.execute("DELETE FROM submit_draft WHERE token=?", (token,))
    c.commit()


def set_app_selection(app_id: int, asset_name: str, bundle_name: str) -> None:
    c = connect()
    c.execute("""INSERT INTO app_selection(app_id,asset_name,bundle_name)
              VALUES (?,?,?) ON CONFLICT(app_id) DO UPDATE SET
              asset_name=excluded.asset_name,bundle_name=excluded.bundle_name""",
              (app_id, asset_name, bundle_name))
    c.commit()


def get_app_selection(app_id: int) -> dict[str, str] | None:
    row = connect().execute("SELECT asset_name,bundle_name FROM app_selection WHERE app_id=?",
                            (app_id,)).fetchone()
    return dict(row) if row else None


def publisher_account_id(app_id: int) -> str | None:
    row = connect().execute("SELECT account_id FROM publisher WHERE app_id=?",
                            (app_id,)).fetchone()
    return row["account_id"] if row else None


def record_download(app_id: int, asset_id: int, device_hash: str = "") -> None:
    c = connect()
    c.execute(
        "INSERT INTO event_download(app_id, asset_id, device_hash, created_at) VALUES (?,?,?,?)",
        (app_id, asset_id, device_hash, int(time.time())),
    )
    c.commit()


def download_counts(app_id: int) -> int:
    return connect().execute(
        "SELECT COUNT(*) AS n FROM event_download WHERE app_id=?", (app_id,)
    ).fetchone()["n"]


# ────────────────────────────── 写入 ──────────────────────────────


def upsert_app(repo_full_name: str, **fields: Any) -> int:
    """插入或更新应用，返回 app.id。"""
    c = connect()
    now = int(time.time())
    row = c.execute(
        "SELECT id FROM app WHERE repo_full_name=?", (repo_full_name,)
    ).fetchone()
    if row:
        app_id = row["id"]
        cols = [k for k in fields if k in _APP_COLUMNS]
        if cols:
            sets = ", ".join(f"{k}=?" for k in cols)
            c.execute(
                f"UPDATE app SET {sets}, updated_at=? WHERE id=?",
                [fields[k] for k in cols] + [now, app_id],
            )
        else:
            c.execute("UPDATE app SET updated_at=? WHERE id=?", (now, app_id))
    else:
        owner, _, name = repo_full_name.partition("/")
        cols = {k: v for k, v in fields.items() if k in _APP_COLUMNS}
        cols.setdefault("display_name", name)
        keys = ["repo_full_name", "owner", "name", "created_at", "updated_at"] + list(cols)
        vals = [repo_full_name, owner, name, now, now] + list(cols.values())
        placeholders = ",".join("?" * len(keys))
        cur = c.execute(
            f"INSERT INTO app({','.join(keys)}) VALUES ({placeholders})", vals
        )
        app_id = cur.lastrowid
    c.commit()
    return app_id


_APP_COLUMNS = {
    "display_name", "summary", "description", "icon_url", "category",
    "tags_json", "stars", "license", "homepage", "verified", "status",
    "featured", "synced_at", "sync_error",
}


def replace_releases(app_id: int, releases: Iterable[dict[str, Any]]) -> int:
    """用采集结果替换该应用的全部 release/asset。返回写入的 release 数。

    **「替换」必须包含删除。** 上游把 Release 或 tag 删掉之后，采集结果里就不再
    有它；如果这里只做 upsert，那条记录会永远留在库里，客户端刷新多少次都还能
    看到 —— 用户在 GitHub 删掉的版本，商店里仍然列着。所以末尾要裁掉本次没出现
    的 release（asset 由外键级联删除，`PRAGMA foreign_keys = ON` 已开启）。
    """
    c = connect()
    now = int(time.time())
    count = 0
    tags: list[str] = []
    for rel in releases:
        tags.append(rel["tag"])
        c.execute(
            """INSERT INTO release(app_id, tag, name, body, published_at,
                                   prerelease, html_url, etag, fetched_at)
               VALUES (?,?,?,?,?,?,?,?,?)
               ON CONFLICT(app_id, tag) DO UPDATE SET
                 name=excluded.name, body=excluded.body,
                 published_at=excluded.published_at,
                 prerelease=excluded.prerelease, html_url=excluded.html_url,
                 etag=excluded.etag, fetched_at=excluded.fetched_at""",
            (
                app_id, rel["tag"], rel.get("name", ""), rel.get("body", ""),
                rel.get("published_at", ""), 1 if rel.get("prerelease") else 0,
                rel.get("html_url", ""), rel.get("etag", ""), now,
            ),
        )
        rid = c.execute(
            "SELECT id FROM release WHERE app_id=? AND tag=?", (app_id, rel["tag"])
        ).fetchone()["id"]
        current_names = [a["name"] for a in rel.get("assets", [])]
        if current_names:
            placeholders = ",".join("?" for _ in current_names)
            c.execute(f"DELETE FROM asset WHERE release_id=? AND name NOT IN ({placeholders})",
                      [rid, *current_names])
        else:
            c.execute("DELETE FROM asset WHERE release_id=?", (rid,))
        # asset 以 (release_id, name) 唯一，直接 upsert
        for a in rel.get("assets", []):
            c.execute(
                """INSERT INTO asset(release_id, name, size, sha256, download_url,
                                     bundle_name, version_code, version_name, min_api)
                   VALUES (?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(release_id, name) DO UPDATE SET
                     size=excluded.size, sha256=excluded.sha256,
                     download_url=excluded.download_url,
                     bundle_name=excluded.bundle_name,
                     version_code=excluded.version_code,
                     version_name=excluded.version_name,
                     min_api=excluded.min_api""",
                (
                    rid, a["name"], a.get("size", 0), a.get("sha256", ""),
                    a.get("download_url", ""), a.get("bundle_name", ""),
                    a.get("version_code", 0), a.get("version_name", ""),
                    a.get("min_api", 0),
                ),
            )
        count += 1
    # 裁掉本次采集里已经不存在的 release（上游删了 tag / Release）。
    # 采集到的列表为空时**不删**：那更可能是抓取失败或限流，而不是作者把
    # 所有版本都撤了 —— 一次网络抖动就清空版本历史是不可接受的。
    if tags:
        placeholders = ",".join("?" for _ in tags)
        c.execute(f"DELETE FROM release WHERE app_id=? AND tag NOT IN ({placeholders})",
                  [app_id, *tags])
    c.commit()
    return count


def set_meta(key: str, value: str) -> None:
    c = connect()
    c.execute(
        "INSERT INTO meta(k,v) VALUES (?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
        (key, value),
    )
    c.commit()


def get_meta(key: str, default: str = "") -> str:
    row = connect().execute("SELECT v FROM meta WHERE k=?", (key,)).fetchone()
    return row["v"] if row else default


def stale_published_apps(max_age_seconds: int, limit: int = 50) -> list[dict[str, Any]]:
    """已经「不新鲜」的已发布应用，字段与 `get_app` 一致。

    与 `apps_needing_sync` 的区别是这里走 `_row_to_app`：采集器只需要
    `repo_full_name`，而接口层要的是 `repo` 这类对外字段。直接用原始 Row 会拿到
    `repo_full_name`，调用方按 `repo` 取就会得到空值 —— 静默什么都没做。
    """
    cutoff = int(time.time()) - max_age_seconds
    rows = connect().execute(
        """SELECT * FROM app WHERE status='published' AND synced_at < ?
           ORDER BY synced_at ASC LIMIT ?""",
        (cutoff, limit),
    ).fetchall()
    return [_row_to_app(row, with_counts=False) for row in rows]


def apps_needing_sync(limit: int = 50, max_age_seconds: int = 6 * 3600) -> list[dict[str, Any]]:
    cutoff = int(time.time()) - max_age_seconds
    rows = connect().execute(
        """SELECT * FROM app WHERE status='published' AND synced_at < ?
           ORDER BY synced_at ASC LIMIT ?""",
        (cutoff, limit),
    ).fetchall()
    return [dict(r) for r in rows]


# ────────────────────────── 镜像链 ──────────────────────────

# 国内可达的 GitHub 加速入口。客户端会用它们做并行竞速，
# 服务器本身在出站受限时也用它采集。
_MIRROR_PREFIXES = (
    "https://gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
)


def mirror_urls(github_url: str) -> list[str]:
    """给定 GitHub 直链，返回可用镜像候选（原链放最后作兜底）。"""
    if not github_url:
        return []
    out = [f"{p}{github_url}" for p in _MIRROR_PREFIXES]
    out.append(github_url)
    return out


def github_api_mirrors(path: str) -> list[str]:
    """给定 GitHub API 路径（如 /repos/a/b/releases），返回候选完整 URL。"""
    raw = f"https://api.github.com{path}"
    out = [f"{p}{raw}" for p in _MIRROR_PREFIXES]
    out.append(raw)
    return out


def stats() -> dict[str, Any]:
    """运维用的总量统计。

    没有对应的 HTTP 路由 —— 客户端从不调用它。保留是因为排查问题时
    `python3 -c "from hapstore import db; print(db.stats())"` 比手写 SQL 快。
    """
    c = connect()
    return {
        "apps": c.execute("SELECT COUNT(*) AS n FROM app").fetchone()["n"],
        "published": c.execute(
            "SELECT COUNT(*) AS n FROM app WHERE status='published'"
        ).fetchone()["n"],
        "releases": c.execute("SELECT COUNT(*) AS n FROM release").fetchone()["n"],
        "assets": c.execute("SELECT COUNT(*) AS n FROM asset").fetchone()["n"],
        "downloads": c.execute("SELECT COUNT(*) AS n FROM event_download").fetchone()["n"],
        "last_sync": get_meta("last_sync", ""),
        "last_sync_ok": get_meta("last_sync_ok", "0"),
    }
