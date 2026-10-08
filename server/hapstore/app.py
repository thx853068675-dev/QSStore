#!/usr/bin/env python3
# Copyright QuietStart contributors. SPDX-License-Identifier: MIT
"""HAP 商店元数据服务 —— HTTP 层。

只用标准库：http.server + socketserver + json + sqlite3。
不引入任何第三方依赖（服务器出站受限，装不了包）。

对外契约见 docs/DESIGN.md §7.3。所有响应统一包装：
    {"ok": true,  "data": {...}, "server_time": "...", "api_version": 1}
    {"ok": false, "error": {"code": "...", "message": "...", "hint": "..."}}
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import secrets
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from . import auth, collector, db, identity_vault, monitor, submissions

API_VERSION = 1
HOST = os.environ.get("HAPSTORE_HOST", "127.0.0.1")
PORT = int(os.environ.get("HAPSTORE_PORT", "8787"))
GITHUB_TOKEN = os.environ.get("HAPSTORE_GITHUB_TOKEN", "")
MONITOR_PASSWORD_HASH = os.environ.get("HAPSTORE_MONITOR_PASSWORD_HASH", "")

# 管理接口只允许本机访问（通过 SSH 隧道使用），绝不暴露公网
ADMIN_ALLOW = {"127.0.0.1", "::1"}

# 简单内存限流：接口与账号（通用接口为 IP）-> [时间戳]
_rl_lock = threading.Lock()
_rl: dict[str, list[float]] = {}

RATE_DEFAULT = (120, 60)     # 120 次 / 60 秒
RATE_SUBMIT = (3, 60)       # 每个已验证账号每分钟 3 次实际预处理
RATE_SYNC = (6, 3600)
# 客户端点「检查更新」会即时重采一个仓库。比 admin 宽一点（用户可能在几个
# 应用间来回切），但仍按 IP 限流，避免被拿来刷 GitHub 配额。
RATE_REFRESH = (10, 3600)
# 批量重采：一次请求会采多个仓库，比单应用接口更贵，所以配额更紧、窗口更长。
RATE_REFRESH_STALE = (6, 3600)
# 一次批量重采最多采几个应用、总时长上限（秒）。GitHub 采集是慢操作，
# 不能让一次下拉刷新把 HTTP 请求拖成几十秒。
REFRESH_STALE_LIMIT = 4
REFRESH_STALE_BUDGET_SECONDS = 12.0


def _client_ip(handler: BaseHTTPRequestHandler) -> str:
    # nginx 反代时带上真实来源
    fwd = handler.headers.get("X-Real-IP") or handler.headers.get("X-Forwarded-For")
    if fwd:
        return fwd.split(",")[0].strip()
    return handler.client_address[0]


def _ip_hash(ip: str) -> str:
    return hashlib.sha256(ip.encode()).hexdigest()[:16]


def _rate_ok(key: str, limit: int, window: int) -> bool:
    return _rate_wait(key, limit, window) == 0


def _rate_wait(key: str, limit: int, window: int) -> int:
    """原子占用一次请求；拒绝时返回真正剩余的等待秒数。"""
    now = time.time()
    with _rl_lock:
        bucket = _rl.setdefault(key, [])
        bucket[:] = [t for t in bucket if now - t < window]
        if len(bucket) >= limit:
            return max(1, math.ceil(bucket[0] + window - now))
        bucket.append(now)
        return 0


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, hint: str = "",
                 retry_after: int = 60):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.hint = hint
        self.retry_after = retry_after


# ────────────────────────────── 路由 ──────────────────────────────


class Router:
    """极简路由：把 (method, 正则) 映射到处理函数。"""

    def __init__(self) -> None:
        self.routes: list[tuple[str, re.Pattern[str], Callable[..., Any]]] = []

    def add(self, method: str, pattern: str, fn: Callable[..., Any]) -> None:
        self.routes.append((method, re.compile(f"^{pattern}$"), fn))

    def match(self, method: str, path: str):
        allowed = False
        for m, pat, fn in self.routes:
            mt = pat.match(path)
            if not mt:
                continue
            if m != method:
                allowed = True
                continue
            return fn, mt.groupdict()
        if allowed:
            raise ApiError(405, "METHOD_NOT_ALLOWED", "该路径不支持此方法")
        return None, None


router = Router()


def _int(value: Any, default: int, lo: int, hi: int) -> int:
    try:
        n = int(value)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, n))


# ── 应用列表 / 详情 ──────────────────────────────────────────────


def h_list_apps(q: dict[str, list[str]]) -> dict[str, Any]:
    featured_raw = (q.get("featured") or [""])[0]
    featured = None
    if featured_raw in ("1", "true"):
        featured = True
    elif featured_raw in ("0", "false"):
        featured = False
    return db.list_apps(
        q=(q.get("q") or [""])[0].strip(),
        category=(q.get("category") or [""])[0].strip(),
        sort=(q.get("sort") or ["updated"])[0],
        direction=(q.get("direction") or [""])[0],
        pagination=(q.get("pagination") or [""])[0],
        snapshot=(q.get("snapshot") or [""])[0][:64],
        featured=featured,
        page=_int((q.get("page") or ["1"])[0], 1, 1, 10000),
        page_size=_int((q.get("page_size") or ["30"])[0], 30, 1, 100),
    )


def h_app_detail(app_id: str, q: dict[str, list[str]]) -> dict[str, Any]:
    app = db.get_app(int(app_id))
    if not app or app["status"] != "published":
        raise ApiError(404, "APP_NOT_FOUND", "应用不存在")
    app["downloads"] = db.download_counts(int(app_id))
    app["rating"] = db.review_summary(int(app_id))
    return app


def h_reviews(app_id: str, q: dict[str, list[str]]) -> dict[str, Any]:
    published = db.get_app(int(app_id))
    if not published or published["status"] != "published":
        raise ApiError(404, "APP_NOT_FOUND", "应用不存在")
    return db.list_reviews(int(app_id),
                           page=_int((q.get("page") or ["1"])[0], 1, 1, 10000),
                           page_size=_int((q.get("page_size") or ["20"])[0], 20, 1, 50))


def h_put_review(app_id: str, body: dict[str, Any], identity: tuple[str, str]) -> dict[str, Any]:
    published = db.get_app(int(app_id))
    if not published or published["status"] != "published":
        raise ApiError(404, "APP_NOT_FOUND", "应用不存在")
    try:
        stars = int(body.get("stars"))
    except (TypeError, ValueError):
        stars = 0
    if not 1 <= stars <= 5:
        raise ApiError(400, "INVALID_RATING", "请给出 1 到 5 星评分")
    if not _rate_ok(f"review:{identity[0]}", 10, 3600):
        raise ApiError(429, "RATE_LIMITED", "评价更新过于频繁，请稍后再试")
    comment = str(body.get("body") or "").strip()
    if len(comment) > 2000:
        raise ApiError(400, "COMMENT_TOO_LONG", "评论不能超过 2000 字")
    db.put_review(int(app_id), identity[0], identity[1], stars, comment)
    # Echo the page the client is now looking at, with the same default the
    # GET route uses, so both responses describe the listing identically.
    return db.list_reviews(int(app_id), page=1, page_size=20)


def h_get_signing_identity(identity: tuple[str, str], cert_id: str = "") -> dict[str, Any]:
    if cert_id and (not cert_id.isdecimal() or len(cert_id) > 64):
        raise ApiError(400, "INVALID_IDENTITY", "证书编号格式不正确")
    return {"identity": identity_vault.get_certificate(identity[0], cert_id) if cert_id
            else identity_vault.get(identity[0])}


def h_put_signing_identity(body: dict[str, Any], identity: tuple[str, str]) -> dict[str, Any]:
    cert_id = str(body.get("cert_id") or "")
    pem = str(body.get("private_key_pem") or "")
    if not cert_id.isdecimal() or len(cert_id) > 64 or not (
        100 <= len(pem) <= 4096 and "-----BEGIN" in pem and "PRIVATE KEY-----" in pem
    ):
        raise ApiError(400, "INVALID_IDENTITY", "签名身份格式不正确")
    try:
        key = serialization.load_pem_private_key(pem.encode("ascii"), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(
            key.curve, ec.SECP256R1
        ):
            raise ValueError("wrong curve")
    except (ValueError, TypeError, UnicodeError):
        raise ApiError(400, "INVALID_IDENTITY", "签名身份格式不正确") from None
    if body.get("backup_scope") == "certificate":
        existing = identity_vault.get_certificate(identity[0], cert_id)
        if existing and existing["private_key_pem"].strip() != pem.strip():
            raise ApiError(409, "IDENTITY_CONFLICT", "该证书的备份私钥不同，已保留原备份和本机材料")
        created = identity_vault.put_certificate(identity[0], cert_id, pem)
        stored = identity_vault.get_certificate(identity[0], cert_id)
        if not stored or stored["private_key_pem"].strip() != pem.strip():
            raise ApiError(409, "IDENTITY_CONFLICT", "该证书的备份已变化，已保留本机材料")
        # Keep the default for older clients; never replace another device's key.
        identity_vault.put_once(identity[0], cert_id, pem)
        return {"created": created, "replaced": False, "synced": True,
                "cert_id": cert_id, "revision": stored["revision"]}
    expect = str(body.get("replace_cert_id") or "")
    revision = body.get("replace_revision")
    if expect and (not expect.isdecimal() or len(expect) > 64 or
                   type(revision) is not int or revision < 1):
        raise ApiError(409, "IDENTITY_CONFLICT", "备份版本不完整，请更新安装器后核对身份")
    created = not expect and identity_vault.put_once(identity[0], cert_id, pem)
    replaced = False
    stored = identity_vault.get(identity[0])
    matches = stored and stored['cert_id'] == cert_id and stored['private_key_pem'].strip() == pem.strip()
    if expect and not matches:
        replaced = identity_vault.replace(identity[0], expect, cert_id, pem, revision)
        stored = identity_vault.get(identity[0])
    # A retried request is successful only if both certificate and key match.
    if not stored or stored["cert_id"] != cert_id or stored["private_key_pem"].strip() != pem.strip():
        raise ApiError(409, "IDENTITY_CONFLICT", "云端身份已变化，保留本机材料，未覆盖云端备份")
    return {
        "created": created,
        "replaced": replaced,
        "synced": True,
        "cert_id": stored["cert_id"],
        "revision": stored["revision"],
    }


def h_app_releases(app_id: str, q: dict[str, list[str]]) -> dict[str, Any]:
    published = db.get_app(int(app_id))
    if not published or published["status"] != "published":
        raise ApiError(404, "APP_NOT_FOUND", "应用不存在")
    return db.list_releases(
        int(app_id),
        page=_int((q.get("page") or ["1"])[0], 1, 1, 10000),
        page_size=_int((q.get("page_size") or ["20"])[0], 20, 1, 50),
        include_prerelease=(q.get("prerelease") or ["0"])[0] == "1",
        prerelease_only=(q.get("prerelease") or ["0"])[0] == "1",
    )


def h_app_release(app_id: str, tag: str, q: dict[str, list[str]]) -> dict[str, Any]:
    published = db.get_app(int(app_id))
    if not published or published["status"] != "published":
        raise ApiError(404, "APP_NOT_FOUND", "应用不存在")
    rel = db.get_release(int(app_id), tag, (q.get('source_repo') or [''])[0])
    if not rel:
        raise ApiError(404, "RELEASE_NOT_FOUND", "该版本不存在")
    return rel


# ── 上架 ────────────────────────────────────────────────────────


SUBMIT_CATEGORIES = (
    # 原有取值全部保留：线上已有记录的 category 必须仍能通过校验，
    # 否则这些应用重新上架或改分类时会被 INVALID_CATEGORY 挡下。
    "工具", "开发工具", "效率", "影音", "游戏", "教育", "生活", "系统工具", "其他",
    # 更细的类型。名字尽量短，滑动选择器一屏放得下。
    "社交通讯", "实用工具", "安全隐私", "阅读", "新闻资讯",
    "摄影录像", "个性化", "出行导航", "购物", "财务",
    "健康运动", "医疗健康", "美食菜谱", "居家生活", "育儿母婴",
    "学习", "办公", "企业应用", "儿童", "无障碍", "政务民生",
)


def _repo_owner_state(repo: str, account_id: str) -> dict[str, Any]:
    """这个仓库在本店的归属：没有记录 / 属于自己 / 属于别人。"""
    row = db.connect().execute(
        "SELECT id,status FROM app WHERE repo_full_name=? COLLATE NOCASE", (repo,)
    ).fetchone()
    if not row:
        return {"state": "new", "app_id": 0}
    if row["status"] != "published":
        return {"state": "new", "app_id": int(row["id"])}
    owner = db.publisher_account_id(row["id"])
    if owner and owner != account_id:
        return {"state": "other", "app_id": int(row["id"])}
    if owner:
        return {"state": "mine", "app_id": int(row["id"])}
    # 有记录但还没归属（采集进来、没人上架）：首次上架按 new 处理
    return {"state": "new", "app_id": int(row["id"])}


def _reject_foreign_repo(repo: str, account_id: str) -> None:
    """别人的仓库不允许重复上架。放在采集之前，避免白跑一次 GitHub 请求。"""
    if _repo_owner_state(repo, account_id)["state"] == "other":
        raise ApiError(403, "PUBLISHER_MISMATCH", "该仓库已由其他账号上架")


def h_submit_prepare(body: dict[str, Any], ip: str,
                     identity: tuple[str, str], *, require_identity: bool = False) -> dict[str, Any]:
    repo = collector.normalize_repo(str(body.get("repo_url") or ""))
    if not repo:
        raise ApiError(400, "INVALID_REPO_URL",
                       "请填写 GitHub 或 Gitee 仓库地址，例如 https://gitee.com/<owner>/<repo>")

    # 同一账号五分钟内重复检查复用完整预处理结果，不重采 HAP、不占额度。
    cached = db.recent_submit_draft(repo, identity[0])
    if cached is not None:
        result = dict(cached["prepared"])
        if require_identity and (result.get('inspection_status') == 'ready' and
                any(not a.get('bundle_name') or not a.get('version_code') or not a.get('sha256')
                    for a in result.get('choices', []))):
            result.update(require_identity=True, inspection_status='pending')
            c = db.connect()
            c.execute('UPDATE submit_draft SET prepared_json=? WHERE token=?',
                      (json.dumps(result), result['draft_token']))
            c.commit()
            db.queue_archive_inspection(result['draft_token'])
            submissions.wake_worker()
        result.pop("snapshot", None)
        result["expires_in_seconds"] = max(0, cached["expires_at"] - int(time.time()))
        result["existing"] = _repo_owner_state(repo, identity[0])
        result["supports_multi_select"] = True
        return result

    account_key = _ip_hash(identity[0])
    wait = _rate_wait(f"submit:{account_key}", *RATE_SUBMIT)
    if wait:
        raise ApiError(429, "RATE_LIMITED", f"检查请求过于频繁，请在 {wait} 秒后重试",
                       retry_after=wait)

    try:
        snapshot = submissions.prepared_snapshot(repo, GITHUB_TOKEN)
        meta = snapshot["metadata"]
        releases = snapshot["releases"]
        candidate = next((r for r in releases if r["assets"]), None)
        if candidate is None:
            raise ApiError(422, "NO_HAP_ASSET",
                           "该仓库的 Release 里没有找到 HAP、APP 或 ZIP 附件",
                           hint="请确认已上传 HAP、APP 或包含安装包的 ZIP")
        # HAP downloads/decoding must never block the old client's 20s request.
        # Cached identity is useful here; missing fields are filled after listing.
        choices = [{
            "tag": candidate["tag"],
            "name": a["name"],
            "size": a["size"],
            "bundle_name": a.get("bundle_name") or "",
            "version_name": a.get("version_name") or "",
            "version_code": a.get("version_code") or 0,
            "min_api": a.get("min_api") or 0,
            "display_name": a.get("display_name") or "",
            "sha256": a.get("sha256") or "",
        } for a in candidate["assets"]]
        token = secrets.token_urlsafe(24)
        needs_inspection = require_identity or any(a['name'].lower().endswith(('.app', '.zip')) for a in candidate['assets'])
        result = {"draft_token": token, "repo": repo, "supports_multi_select": True,
                "inspection_status": 'pending' if needs_inspection else 'ready',
                "display_name": meta["display_name"],
                "description": meta["description"],
                "choices": choices,
                "suggested_category": meta["category"],
                "categories": SUBMIT_CATEGORIES,
                # 客户端据此提示「这是更新已有的那条」还是「已被别人上架」
                "existing": _repo_owner_state(repo, identity[0]),
                "expires_in_seconds": 1800}
        stored = dict(result, snapshot=snapshot, require_identity=require_identity)
        db.create_submit_draft(token, repo, identity[0], choices, meta["category"], stored)
        if needs_inspection:
            db.queue_archive_inspection(token)
            submissions.wake_worker()
        return result
    except ApiError:
        raise
    except collector.CollectError as e:
        raise ApiError(502, "COLLECT_FAILED", f"无法读取该仓库：{e}",
                       hint="请确认仓库公开可见且包含 Release") from e
    except Exception as e:  # noqa: BLE001
        raise ApiError(500, "PREPARE_FAILED", f"检查失败：{e}") from e


def h_submit_status(body: dict[str, Any], identity: tuple[str, str]) -> dict[str, Any]:
    draft = db.get_submit_draft(str(body.get('draft_token') or ''), identity[0])
    if not draft: raise ApiError(404, 'DRAFT_EXPIRED', '检查结果已过期，请重新检查')
    if draft['inspection_state'] == 'error':
        raise ApiError(422, 'INVALID_PACKAGE_ARCHIVE', draft['inspection_error'])
    result = json.loads(draft['prepared_json'])
    result.pop('snapshot', None)
    result['inspection_status'] = draft['inspection_state']
    result['existing'] = _repo_owner_state(draft['repo'], identity[0])
    result["supports_multi_select"] = True
    return result


def h_submit_confirm(body: dict[str, Any], identity: tuple[str, str]) -> dict[str, Any]:
    draft = db.get_submit_draft(str(body.get("draft_token") or ""), identity[0])
    if draft is None:
        raise ApiError(404, "DRAFT_EXPIRED", "检查结果已过期，请重新检查仓库")
    if draft['inspection_state'] != 'ready':
        raise ApiError(409, 'PACKAGE_INSPECTION_PENDING', '安装包仍在检查，请稍候')
    names = body.get('asset_names', [body.get('asset_name', '')])
    if (not isinstance(names, list) or not names or len(names) > 32 or
            any(not isinstance(name, str) for name in names) or len(set(names)) != len(names)):
        raise ApiError(400, 'INVALID_ASSET', '请选择一个或多个安装包')
    choices = [next((a for a in draft['choices'] if a['name'] == name), None) for name in names]
    if any(choice is None for choice in choices):
        raise ApiError(400, 'INVALID_ASSET', '请选择检查列表中的安装包')
    category = str(body.get("category") or "")
    if category not in SUBMIT_CATEGORIES:
        raise ApiError(400, "INVALID_CATEGORY", "请选择应用分类")
    # 先判归属再同步：别人的仓库直接拒绝，不必浪费一次 GitHub 采集
    _reject_foreign_repo(draft["repo"], identity[0])
    try:
        stored = json.loads(draft["prepared_json"])
        # Drafts created before this rollout retain the same token and choices.
        snapshot = stored.get("snapshot") or submissions.prepared_snapshot(draft["repo"], GITHUB_TOKEN)
        app_id = db.publish_prepared_app(draft["token"], identity[0], identity[1],
                                        category, choices, snapshot)
    except ValueError as e:
        errors = {
            "DRAFT_EXPIRED": (404, "检查结果已过期，请重新检查仓库"),
            "APP_UNLISTED": (409, "该应用已下架，请重新检查仓库后上架"),
            "PUBLISHER_MISMATCH": (403, "该仓库已由其他账号上架"),
            "INVALID_ASSET": (409, "所选 HAP 已变化，请重新检查仓库"),
        }
        if str(e) not in errors:
            raise
        status, message = errors[str(e)]
        raise ApiError(status, str(e), message) from e
    except collector.CollectError as e:
        raise ApiError(502, "COLLECT_FAILED", f"上架检查失败：{e}") from e
    submissions.wake_worker()
    return {"app": db.get_app(app_id), "status": "ok"}


def h_refresh_stale_apps(ip: str, limit: int, budget_seconds: float,
                         app_ids: list[int] | None = None) -> dict[str, Any]:
    """Compatibility endpoint: queue stale apps, never collect inside HTTP."""
    if not _rate_ok(f"refresh-stale:{ip}", *RATE_REFRESH_STALE):
        raise ApiError(429, 'RATE_LIMITED', '刷新过于频繁，请稍后再试')
    max_age = _int(os.environ.get('HAPSTORE_REFRESH_MAX_AGE'), 300, 0, 86400)
    rows = ([db.get_app(i) for i in dict.fromkeys(app_ids) if i > 0][:limit] if app_ids else
            db.stale_published_apps(max_age_seconds=max_age, limit=limit))
    queued, skipped = [], []
    for row in rows:
        if not row or row['status'] != 'published':
            continue
        state = db.enqueue_catalog_refresh(row['id'], max_age)
        if state['queued']:
            queued.append({'app_id': row['id'], 'repo': row['repo'], 'status': state['status']})
        else:
            skipped.append(row['id'])
    if queued:
        submissions.wake_worker()
    return {'queued': queued, 'refreshed': [], 'skipped': skipped, 'failures': [],
            'considered': len(rows), 'max_age': max_age}


def h_refresh_app(app_id: str, ip: str) -> dict[str, Any]:
    if not _rate_ok(f'refresh:{ip}', *RATE_REFRESH):
        raise ApiError(429, 'RATE_LIMITED', '检查过于频繁，请稍后再试')
    details = db.get_app(int(app_id))
    if not details or details['status'] != 'published':
        raise ApiError(404, 'APP_NOT_FOUND', '应用不存在')
    state = db.enqueue_catalog_refresh(int(app_id), 60)
    if state['queued']:
        submissions.wake_worker()
    return dict(state, repo=details['repo'], latest=details.get('latest'),
                latest_asset=details.get('latest_asset'), releases=details.get('releases_count', 0))


def h_refresh_status(app_id: str) -> dict[str, Any]:
    row = db.connect().execute("SELECT status FROM app WHERE id=?", (int(app_id),)).fetchone()
    if not row or row['status'] != 'published':
        raise ApiError(404, 'APP_NOT_FOUND', '应用不存在')
    return db.catalog_refresh_status(int(app_id))


def h_my_apps(identity: tuple[str, str]) -> dict[str, Any]:
    return {"items": db.list_published_by_account(identity[0])}


def h_remove_my_app(app_id: str, identity: tuple[str, str]) -> dict[str, Any]:
    app = db.get_app(int(app_id))
    if not app or app["status"] != "published":
        raise ApiError(404, "APP_NOT_FOUND", "应用不存在")
    if db.publisher_account_id(int(app_id)) != identity[0]:
        raise ApiError(403, "PUBLISHER_MISMATCH", "只能删除自己上架的应用")
    if not db.hide_published_app(int(app_id), identity[0]):
        raise ApiError(404, "APP_NOT_FOUND", "应用不存在")
    return {"removed": True, "app_id": int(app_id)}


def h_configure_my_app(app_id: str, body: dict[str, Any],
                       identity: tuple[str, str]) -> dict[str, Any]:
    published = db.get_app(int(app_id))
    if not published or published["status"] != "published":
        raise ApiError(404, "APP_NOT_FOUND", "应用不存在")
    if db.publisher_account_id(int(app_id)) != identity[0]:
        raise ApiError(403, "PUBLISHER_MISMATCH", "只能配置自己上架的应用")
    category = body.get("category")
    if not isinstance(category, str) or category not in SUBMIT_CATEGORIES:
        raise ApiError(400, "INVALID_CATEGORY", "请选择有效的软件分类")
    token = body.get('source_draft_token', '')
    remove = body.get('remove_secondary', False)
    if not isinstance(token, str) or type(remove) is not bool or (token and remove):
        raise ApiError(400, 'INVALID_SOURCE', '请选择有效的子仓配置')
    try:
        db.configure_app_source(int(app_id), identity[0], category, token, remove)
    except ValueError as error:
        errors = {
            'PUBLISHER_MISMATCH': (403, '只能配置自己上架的应用'),
            'SOURCE_DRAFT_NOT_READY': (409, '子仓检查未完成或已过期，请重新检查'),
            'SOURCE_IS_PRIMARY': (400, '子仓不能与主仓相同'),
            'SOURCE_BUNDLE_MISMATCH': (422, '子仓安装包与主仓的包名不一致，无法关联'),
        }
        status, message = errors.get(str(error), (409, '子仓配置已变化，请重新检查'))
        raise ApiError(status, str(error), message) from error
    if token:
        db.enqueue_catalog_refresh(int(app_id), 300)
        submissions.wake_worker()
    return {"app": db.get_app(int(app_id))}


def h_prepare_app_source(app_id: str, body: dict[str, Any], ip: str,
                         identity: tuple[str, str]) -> dict[str, Any]:
    published = db.get_app(int(app_id))
    if not published or published['status'] != 'published':
        raise ApiError(404, 'APP_NOT_FOUND', '应用不存在')
    if db.publisher_account_id(int(app_id)) != identity[0]:
        raise ApiError(403, 'PUBLISHER_MISMATCH', '只能配置自己上架的应用')
    repo = collector.normalize_repo(str(body.get('repo_url') or ''))
    if repo and repo.lower() == published['repo'].lower():
        raise ApiError(400, 'SOURCE_IS_PRIMARY', '子仓不能与主仓相同')
    if not db.primary_bundles(int(app_id)):
        raise ApiError(409, 'PRIMARY_IDENTITY_PENDING', '主仓包名尚未解析完成，请稍后重试')
    return h_submit_prepare(body, ip, identity, require_identity=True)


def h_admin_sync(body: dict[str, Any], ip: str) -> dict[str, Any]:
    if not _rate_ok("admin_sync", *RATE_SYNC):
        raise ApiError(429, "RATE_LIMITED", "同步过于频繁")
    repo = collector.normalize_repo(str(body.get("repo") or ""))
    if repo:
        return collector.sync_app(repo, token=GITHUB_TOKEN)
    limit = _int(body.get("limit"), 10, 1, 50)
    return submissions.queue_due(limit=limit)


def h_admin_channels(q: dict[str, list[str]]) -> dict[str, Any]:
    return collector.probe_channels()


def h_admin_hide(app_id: str, body: dict[str, Any]) -> dict[str, Any]:
    app = db.get_app(int(app_id))
    if not app:
        raise ApiError(404, "APP_NOT_FOUND", "应用不存在")
    status = "hidden" if str(body.get("status") or "hidden") == "hidden" else "published"
    db.upsert_app(app["repo"], status=status)
    return {"app_id": app["id"], "status": status}


def h_admin_feature(app_id: str, body: dict[str, Any]) -> dict[str, Any]:
    app = db.get_app(int(app_id))
    if not app:
        raise ApiError(404, "APP_NOT_FOUND", "应用不存在")
    featured = 1 if body.get("featured") else 0
    db.upsert_app(app["repo"], featured=featured)
    return {"app_id": app["id"], "featured": bool(featured)}


# 注册路由
router.add("GET", r"/api/v1/apps", h_list_apps)
router.add("GET", r"/api/v1/apps/(?P<app_id>\d+)", h_app_detail)
router.add("GET", r"/api/v1/apps/(?P<app_id>\d+)/reviews", h_reviews)
router.add("POST", r"/api/v1/apps/(?P<app_id>\d+)/reviews", "REVIEW")
router.add("GET", r"/api/v1/apps/(?P<app_id>\d+)/releases", h_app_releases)
router.add("GET", r"/api/v1/apps/(?P<app_id>\d+)/releases/(?P<tag>[^/]+)", h_app_release)
router.add("GET", r"/api/v1/healthz", lambda q: {"ok": True, "stage": "M1"})
router.add("GET", r"/api/v1/monitor", "MONITOR")
router.add("GET", r"/api/v1/me/presence", "PRESENCE")
router.add("POST", r"/api/v1/submit/prepare", "SUBMIT_PREPARE")
router.add("POST", r"/api/v1/submit/confirm", "SUBMIT_CONFIRM")
router.add("POST", r"/api/v1/submit/status", "SUBMIT_STATUS")
router.add("POST", r"/api/v1/apps/refresh-stale", "APPS_REFRESH_STALE")
router.add("POST", r"/api/v1/apps/(?P<app_id>\d+)/refresh", "APP_REFRESH")
router.add("GET", r"/api/v1/apps/(?P<app_id>\d+)/refresh", "APP_REFRESH_STATUS")
router.add("GET", r"/api/v1/me/apps", "MY_APPS")
router.add("GET", r"/api/v1/categories", lambda q: {"items": SUBMIT_CATEGORIES})
router.add("POST", r"/api/v1/me/apps/(?P<app_id>\d+)/category", "MY_APP_CONFIGURE")
router.add("POST", r"/api/v1/me/apps/(?P<app_id>\d+)/source/prepare", "MY_APP_SOURCE_PREPARE")
router.add("DELETE", r"/api/v1/me/apps/(?P<app_id>\d+)", "MY_APP_DELETE")
router.add("GET", r"/api/v1/signing-identity", "IDENTITY_GET")
router.add("POST", r"/api/v1/signing-identity", "IDENTITY_PUT")
router.add("GET", r"/api/v1/admin/sync", h_admin_channels)   # 探测通道
router.add("POST", r"/api/v1/admin/sync", "ADMIN_SYNC")
router.add("POST", r"/api/v1/admin/apps/(?P<app_id>\d+)/hide", "ADMIN_HIDE")
router.add("POST", r"/api/v1/admin/apps/(?P<app_id>\d+)/feature", "ADMIN_FEATURE")


# ────────────────────────────── Handler ──────────────────────────────


class Handler(BaseHTTPRequestHandler):
    server_version = "hapstore/1.0"
    protocol_version = "HTTP/1.1"

    # ── 通用工具 ──
    def _send(self, status: int, payload: bytes, ctype: str,
              extra: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        # 安全响应头（nginx 也会加，这里保证直连时同样具备）
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        if 'Cache-Control' not in (extra or {}):
            self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _json(self, data: Any, status: int = 200, public: bool = False) -> None:
        body = json.dumps(
            {"ok": True, "data": data, "server_time": _now_iso(), "api_version": API_VERSION},
            ensure_ascii=False,
        ).encode("utf-8")
        if public and status == 200:
            etag = '"' + hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:24] + '"'
            headers = {'ETag': etag, 'Cache-Control': 'public, max-age=30, must-revalidate'}
            if self.headers.get('If-None-Match') == etag:
                self._send(304, b'', 'application/json; charset=utf-8', headers)
            else:
                self._send(status, body, 'application/json; charset=utf-8', headers)
        else:
            self._send(status, body, "application/json; charset=utf-8")

    def _error(self, status: int, code: str, message: str, hint: str = "",
               retry_after: int = 60) -> None:
        err = {"code": code, "message": message}
        if hint:
            err["hint"] = hint
        body = json.dumps(
            {"ok": False, "error": err, "server_time": _now_iso(), "api_version": API_VERSION},
            ensure_ascii=False,
        ).encode("utf-8")
        if status == 429:
            self._send(status, body, "application/json; charset=utf-8",
                       {"Retry-After": str(retry_after)})
        else:
            self._send(status, body, "application/json; charset=utf-8")

    def _read_body(self) -> dict[str, Any]:
        length = _int(self.headers.get("Content-Length"), 0, 0, 32768)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except Exception as e:  # noqa: BLE001
            raise ApiError(400, "INVALID_JSON", "请求体不是合法 JSON") from e
        if not isinstance(data, dict):
            raise ApiError(400, "INVALID_JSON", "请求体必须是 JSON 对象")
        return data

    def _identity(self) -> tuple[str, str]:
        header = self.headers.get("Authorization", "")
        token = header[7:] if header.startswith("Bearer ") else ""
        access_token = self.headers.get("X-Huawei-Access-Token", "")
        try:
            identity = auth.verify(token, access_token)
            db.sync_account_profile(*identity, auth.verified_avatar(token, access_token))
            monitor.record_authenticated_account(identity[0])
            return identity
        except auth.InvalidIdentity as exc:
            raise ApiError(401, "SIGN_IN_REQUIRED", str(exc)) from None
        except auth.IdentityUnavailable as exc:
            raise ApiError(503, "IDENTITY_UNAVAILABLE", str(exc)) from None

    # ── 分发 ──
    def _handle(self, method: str) -> None:
        ip = _client_ip(self)
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        query = parse_qs(parsed.query)

        try:
            if not _rate_ok(f"api:{ip}", *RATE_DEFAULT):
                raise ApiError(429, "RATE_LIMITED", "请求过于频繁，请稍后再试")

            # Only serve the image extracted from the selected HAP.
            m = re.match(r"^/api/v1/apps/(\d+)/icon$", path)
            if m and method == "GET":
                app_id = int(m.group(1))
                app = db.connect().execute('SELECT status FROM app WHERE id=?', (app_id,)).fetchone()
                if not app or app["status"] != "published":
                    raise ApiError(404, "ICON_NOT_FOUND", "该应用没有图标")
                icon = db.app_icon(app_id)
                if icon:
                    etag = '"' + hashlib.sha256(icon[1]).hexdigest()[:16] + '"'
                    supplied_rev = (query.get('v') or query.get('rev') or [''])[0]
                    immutable = supplied_rev == etag.strip('"')
                    headers = {'ETag': etag, 'Cache-Control': 'public, max-age=31536000, immutable' if immutable else 'public, max-age=300, must-revalidate'}
                    self._send(304 if self.headers.get('If-None-Match') == etag else 200,
                               b'' if self.headers.get('If-None-Match') == etag else icon[1], icon[0], headers)
                    return
                raise ApiError(404, "ICON_NOT_FOUND", "该应用没有包内图标")

            fn, params = router.match(method, path)
            if fn is None:
                raise ApiError(404, "NOT_FOUND", f"未知接口：{path}")

            # 管理接口仅本机
            if path.startswith("/api/v1/admin/") and ip not in ADMIN_ALLOW:
                raise ApiError(403, "FORBIDDEN", "管理接口仅限本机访问")

            if fn == "MONITOR":
                supplied = self.headers.get("Authorization", "")
                if not monitor.password_configured(MONITOR_PASSWORD_HASH):
                    raise ApiError(503, "MONITOR_DISABLED", "监控密码尚未配置")
                if not _rate_ok(f"monitor:{ip}", 10, 60):
                    raise ApiError(429, "MONITOR_RATE_LIMITED", "尝试过于频繁，请一分钟后再试")
                if not monitor.verify_authorization(supplied, MONITOR_PASSWORD_HASH):
                    raise ApiError(401, "MONITOR_UNAUTHORIZED", "监控密码不正确")
                self._json(monitor.snapshot(GITHUB_TOKEN))
            elif fn == "PRESENCE":
                self._identity()
                self._json({"recorded": True})
            elif fn == "SUBMIT_PREPARE":
                self._json(h_submit_prepare(self._read_body(), ip, self._identity()))
            elif fn == "SUBMIT_STATUS":
                self._json(h_submit_status(self._read_body(), self._identity()))
            elif fn == "SUBMIT_CONFIRM":
                self._json(h_submit_confirm(self._read_body(), self._identity()))
            elif fn == "APPS_REFRESH_STALE":
                requested = self._read_body().get("app_ids")
                ids = [int(v) for v in requested
                       if isinstance(v, (int, float))] if isinstance(requested, list) else None
                self._json(h_refresh_stale_apps(ip, REFRESH_STALE_LIMIT,
                                                REFRESH_STALE_BUDGET_SECONDS, ids))
            elif fn == "APP_REFRESH":
                self._json(h_refresh_app(params["app_id"], ip))
            elif fn == "APP_REFRESH_STATUS":
                self._json(h_refresh_status(params['app_id']))
            elif fn == "MY_APPS":
                self._json(h_my_apps(self._identity()))
            elif fn == "MY_APP_DELETE":
                self._json(h_remove_my_app(params["app_id"], self._identity()))
            elif fn == "MY_APP_CONFIGURE":
                self._json(h_configure_my_app(params["app_id"], self._read_body(), self._identity()))
            elif fn == "MY_APP_SOURCE_PREPARE":
                self._json(h_prepare_app_source(params['app_id'], self._read_body(), ip, self._identity()))
            elif fn == "REVIEW":
                self._json(h_put_review(params["app_id"], self._read_body(), self._identity()))
            elif fn == "IDENTITY_GET":
                data = h_get_signing_identity(self._identity(), (query.get("cert_id") or [""])[0])
                payload = json.dumps({"ok": True, "data": data,
                    "server_time": _now_iso(), "api_version": API_VERSION},
                    ensure_ascii=False).encode("utf-8")
                self._send(200, payload, "application/json; charset=utf-8",
                           {"Cache-Control": "no-store"})
            elif fn == "IDENTITY_PUT":
                self._json(h_put_signing_identity(self._read_body(), self._identity()))
            elif fn == "ADMIN_SYNC":
                self._json(h_admin_sync(self._read_body(), ip))
            elif fn == "ADMIN_HIDE":
                self._json(h_admin_hide(params["app_id"], self._read_body()))
            elif fn == "ADMIN_FEATURE":
                self._json(h_admin_feature(params["app_id"], self._read_body()))
            elif "app_id" in params and "tag" in params:
                self._json(fn(params["app_id"], params["tag"], query), public=True)
            elif "app_id" in params:
                self._json(fn(params["app_id"], query), public=True)
            elif "task_id" in params:
                self._json(fn(params["task_id"], query))
            else:
                self._json(fn(query), public=not path.startswith("/api/v1/admin/"))
        except ApiError as e:
            self._error(e.status, e.code, e.message, e.hint, e.retry_after)
        except BrokenPipeError:
            pass
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            self._error(500, "INTERNAL", f"服务器内部错误：{type(e).__name__}")

    def do_GET(self) -> None:      # noqa: N802
        self._handle("GET")

    def do_POST(self) -> None:     # noqa: N802
        self._handle("POST")

    def do_DELETE(self) -> None:   # noqa: N802
        self._handle("DELETE")

    def do_HEAD(self) -> None:     # noqa: N802
        self._handle("GET")

    def log_message(self, fmt: str, *args: Any) -> None:
        # 交给 systemd journal，格式收紧
        print(f"{_client_ip(self)} {self.command} {self.path} - {fmt % args}",
              flush=True)


def serve_forever() -> None:
    db.init_db()
    submissions.start_worker(GITHUB_TOKEN)
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.daemon_threads = True
    print(f"hapstore api listening on http://{HOST}:{PORT}", flush=True)

    # 后台采集线程：出站可用时按周期刷新；不可用时静默降级。
    interval = int(os.environ.get("HAPSTORE_SYNC_INTERVAL", "21600"))  # 6 小时
    if interval > 0:
        def loop() -> None:
            time.sleep(60)  # 启动后先等一会儿
            while True:
                try:
                    result = submissions.queue_due(limit=20,
                                               progress=lambda s: print(s, flush=True))
                    print(f"sync done: {result}", flush=True)
                except Exception as e:  # noqa: BLE001
                    print(f"sync failed: {e}", flush=True)
                time.sleep(interval)

        threading.Thread(target=loop, name="collector", daemon=True).start()

    httpd.serve_forever()


if __name__ == "__main__":
    serve_forever()
