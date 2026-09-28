#!/usr/bin/env python3
# Copyright QuietStart contributors. SPDX-License-Identifier: MIT
"""GitHub release 采集器。

两个关键设计：

1) **可信元数据与镜像下载**
   release 摘要和下载地址只从 GitHub API 直连取得。镜像只用于下载 HAP；
   下载后必须匹配 GitHub 摘要才会解析包内元数据。直连不可用时同步失败，
   防止第三方镜像同时伪造安装包与校验值。

2) **不落盘 HAP 本体**
   为了从包里读出 bundleName / versionCode（用于兼容性与更新判断），
   需要读 HAP 内的小文件。做法是把包下到临时文件后**只读需要的条目**，
   随后立即删除 —— 服务器只保留索引，不保留安装包。

关于 versionCode 的坑：
   实测轻启的 `module.json` 里 `app.versionCode=110003`，而 `pack.info` 里
   `summary.app.version.code=110011`。**安装时设备认的是 pack.info 的值**
   （这正是用 1.1.0 包安装时被判定为「降级」的原因）。因此这里优先取
   pack.info，取不到才回退 module.json。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import ssl
import struct
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from typing import Any, Callable
from urllib.parse import urlparse

from . import db

USER_AGENT = "hapstore-collector/1.0 (+https://github.com/)"
TIMEOUT = 20
MAX_HAP_SCAN = 300 * 1024 * 1024  # 超过这个大小就不下回来解析了

# 仅用于下载 HAP / 探测线路，不用于取得可信摘要。
API_MIRRORS = (
    "https://gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
    "",  # 空串代表直连
)

_CTX = ssl.create_default_context()


class CollectError(Exception):
    pass


def _http_get(url: str, *, token: str = "", accept: str = "application/vnd.github+json",
              timeout: int = TIMEOUT) -> bytes:
    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": accept,
    })
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=timeout, context=_CTX) as resp:
        return resp.read()


def _try_chain(path: str, *, token: str = "") -> tuple[bytes, str]:
    """摘要和下载地址只能取自 GitHub；不能让第三方代理签发校验值。"""
    try:
        return _http_get(f"https://api.github.com{path}", token=token), "direct"
    except Exception as e:
        raise CollectError(f"GitHub API 直连失败（{path}）：{e}") from e


def _json(path: str, *, token: str = "") -> Any:
    body, _ = _try_chain(path, token=token)
    return json.loads(body.decode("utf-8", "replace"))


# ───────────────────────── HAP 内嵌元数据 ─────────────────────────


def parse_hap_metadata(path: str) -> dict[str, Any]:
    """从本地 HAP 文件读取 bundleName / versionCode / versionName / minAPI。

    优先 pack.info（设备安装时的权威值），回退 module.json。
    """
    out: dict[str, Any] = {
        "bundle_name": "", "version_code": 0, "version_name": "", "min_api": 0,
        "display_name": "",
    }
    try:
        with zipfile.ZipFile(path) as z:
            names = set(z.namelist())

            # ① pack.info —— 权威来源
            if "pack.info" in names:
                try:
                    info = json.loads(z.read("pack.info"))
                    summary = (info.get("summary") or {}).get("app") or {}
                    out["bundle_name"] = summary.get("bundleName", "") or out["bundle_name"]
                    v = summary.get("version") or {}
                    if isinstance(v, dict):
                        out["version_code"] = int(v.get("code") or 0)
                        out["version_name"] = str(v.get("name") or "")
                    else:
                        out["version_code"] = int(v or 0)
                except Exception:
                    pass

            # ② module.json —— 回退与补齐
            if "module.json" in names:
                try:
                    m = json.loads(z.read("module.json"))
                    app = m.get("app") or {}
                    out["bundle_name"] = app.get("bundleName") or out["bundle_name"]
                    if not out["version_code"]:
                        out["version_code"] = int(app.get("versionCode") or 0)
                    if not out["version_name"]:
                        out["version_name"] = str(app.get("versionName") or "")
                    out["min_api"] = int(app.get("minAPIVersion") or 0)
                    label = str(app.get("label") or "").strip()
                    if label and not label.startswith("$string:"):
                        out["display_name"] = label
                    elif "resources.index" in names and z.getinfo("resources.index").file_size <= 4 * 1024 * 1024:
                        label_id = int(app.get("labelId") or 0)
                        if label_id:
                            out["display_name"] = _resource_string(
                                z.read("resources.index"), label_id)
                except Exception:
                    pass
    except zipfile.BadZipFile:
        return out
    except Exception:
        return out
    return out


def _resource_string(data: bytes, resource_id: int) -> str:
    """Resolve an app label from the bounded RestoolV2 resource index.

    The index maps the module's labelId to one or more localized string
    values. Prefer the default configuration; otherwise use the first value.
    Malformed or unfamiliar indexes are ignored rather than guessed from
    unrelated strings in the package.
    """
    def u32(pos: int) -> int:
        if pos < 0 or pos + 4 > len(data):
            raise ValueError("resource index offset")
        return struct.unpack_from("<I", data, pos)[0]

    try:
        if len(data) > 4 * 1024 * 1024 or not data.startswith(b"RestoolV2"):
            return ""
        if u32(128) != len(data):
            return ""
        key_count = u32(132)
        if key_count > 256:
            return ""
        pos = 140
        for _ in range(key_count):
            if data[pos:pos + 4] != b"KEYS":
                return ""
            count = u32(pos + 8)
            pos += 12 + count * 8
            if pos > len(data):
                return ""
        if data[pos:pos + 4] != b"IDSS":
            return ""
        type_count = u32(pos + 8)
        if type_count > 256:
            return ""
        pos += 16
        for _ in range(type_count):
            entry_count = u32(pos + 8)
            pos += 12
            for _ in range(entry_count):
                rid, offset, name_len = struct.unpack_from("<III", data, pos)
                pos += 12 + name_len
                if pos > len(data):
                    return ""
                if rid != resource_id:
                    continue
                if u32(offset) != rid:
                    return ""
                value_count = u32(offset + 8)
                fallback = ""
                for i in range(min(value_count, 64)):
                    config_id = u32(offset + 12 + i * 8)
                    value_at = u32(offset + 16 + i * 8)
                    size = struct.unpack_from("<H", data, value_at)[0]
                    if size > 512 or value_at + 2 + size > len(data):
                        continue
                    value = data[value_at + 2:value_at + 2 + size].decode("utf-8")
                    if value and config_id == 0:
                        return value[:100]
                    if value and not fallback:
                        fallback = value[:100]
                return fallback
    except (ValueError, UnicodeError, struct.error):
        return ""
    return ""


def extract_hap_icon(path: str) -> tuple[str, bytes] | None:
    """Best-effort icon extraction from a digest-verified HAP.

    Compiled resource ids differ by build system, so only accept small image
    entries whose filenames explicitly look like app icons.
    """
    try:
        with zipfile.ZipFile(path) as archive:
            candidates = []
            for entry in archive.infolist():
                name = entry.filename.lower()
                base = name.rsplit("/", 1)[-1]
                if ("icon" not in base or entry.file_size < 100 or
                        entry.file_size > 1024 * 1024 or
                        not base.endswith((".png", ".jpg", ".jpeg", ".webp"))):
                    continue
                score = (20 if "app_icon" in base or "appicon" in base else 0)
                score += 10 if "/media/" in name else 0
                score += 5 if "foreground" not in base else 0
                candidates.append((score, entry))
            for _, entry in sorted(candidates, key=lambda item: item[0], reverse=True):
                data = archive.read(entry)
                if data.startswith(b"\x89PNG\r\n\x1a\n"):
                    return "image/png", data
                if data.startswith(b"\xff\xd8\xff"):
                    return "image/jpeg", data
                if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
                    return "image/webp", data
    except (OSError, zipfile.BadZipFile, RuntimeError):
        pass
    return None


_CATEGORY_KEYWORDS = (
    ("游戏", ("game", "gaming", "游戏")),
    ("开发工具", ("developer", "development", "ide", "编程", "开发")),
    ("影音", ("music", "audio", "video", "player", "media", "音乐", "视频")),
    ("效率", ("productivity", "notes", "todo", "calendar", "笔记", "效率")),
    ("系统工具", ("system", "launcher", "settings", "系统")),
    ("工具", ("utility", "utilities", "tools", "工具")),
)


def classify_repo(topics: list[str], description: str = "") -> str:
    """Category heuristic from GitHub topics and description; otherwise 其他."""
    values = " ".join(str(topic).lower() for topic in topics)
    values += " " + description.lower()
    for category, words in _CATEGORY_KEYWORDS:
        if any(word in values for word in words):
            return category
    return "其他"


def _unlink_quiet(path: str | None) -> None:
    if not path:
        return
    try:
        if os.path.exists(path):
            os.unlink(path)
    except OSError:
        pass


def _download_to_temp(url: str, *, token: str = "") -> str | None:
    """把 HAP 下到临时文件用于解析。失败返回 None（不阻断采集）。

    重要：**超限截断的文件必须丢弃**。超限时若把已写入的临时文件当完整包返回，
    随后按它算出的 sha256 是错的，一旦入库就会毒害客户端的完整性校验 ——
    客户端会拿这个错误哈希去比对，从而拒掉本来正常的包（或反之放行被截断的包）。
    """
    for prefix in API_MIRRORS:
        target = f"{prefix}{url}" if prefix else url
        tmp: str | None = None
        try:
            req = urllib.request.Request(target, headers={"User-Agent": USER_AGENT})
            if token and not prefix:
                req.add_header("Authorization", f"Bearer {token}")
            fd, tmp = tempfile.mkstemp(suffix=".hap", prefix="hapstore-")
            os.close(fd)
            length = 0
            total = 0
            truncated = False
            with urllib.request.urlopen(req, timeout=60, context=_CTX) as resp, open(tmp, "wb") as f:
                length = int(resp.headers.get("Content-Length") or 0)
                if length and length > MAX_HAP_SCAN:
                    _unlink_quiet(tmp)
                    tmp = None
                    continue
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_HAP_SCAN:
                        truncated = True
                        break
                    f.write(chunk)
            # 截断、空文件、或与实际声明长度不符 → 视为「未扫描」，丢弃换下一个镜像。
            if truncated or total == 0 or (length and total != length):
                _unlink_quiet(tmp)
                tmp = None
                continue
            return tmp
        except Exception:
            _unlink_quiet(tmp)
            continue
    return None


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ───────────────────────── 仓库解析 ─────────────────────────


REPO_RE = re.compile(
    r"^(?:https?://)?(?:www\.)?github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$"
)


def normalize_repo(repo_url: str) -> str | None:
    """把用户输入的 GitHub 地址规范化为 owner/repo。"""
    repo_url = (repo_url or "").strip()
    if not repo_url:
        return None
    m = REPO_RE.match(repo_url)
    if m:
        return f"{m.group(1)}/{m.group(2)}"
    # 允许直接填 owner/repo
    m = re.match(r"^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$", repo_url)
    if m:
        return f"{m.group(1)}/{m.group(2)}"
    return None


def is_hap_asset(name: str) -> bool:
    return name.lower().endswith(".hap")


# ───────────────────────── 采集主流程 ─────────────────────────


def fetch_app_metadata(repo: str, *, token: str = "") -> dict[str, Any]:
    """拉取仓库基础信息。"""
    data = _json(f"/repos/{repo}", token=token)
    return {
        "display_name": data.get("name") or repo.split("/")[-1],
        "description": data.get("description") or "",
        "summary": (data.get("description") or "")[:120],
        "stars": int(data.get("stargazers_count") or 0),
        "homepage": data.get("homepage") or "",
        "license": ((data.get("license") or {}) or {}).get("spdx_id") or "",
        "tags_json": json.dumps(data.get("topics") or [], ensure_ascii=False),
        "category": classify_repo(data.get("topics") or [], data.get("description") or ""),
        "icon_url": f"https://github.com/{repo.split('/')[0]}.png",
    }


def fetch_releases(repo: str, *, token: str = "", limit: int = 30) -> list[dict[str, Any]]:
    """拉取 release 列表并筛出 HAP 附件。"""
    raw = _json(f"/repos/{repo}/releases?per_page={limit}", token=token)
    out: list[dict[str, Any]] = []
    for r in raw:
        assets = []
        for a in r.get("assets") or []:
            if not is_hap_asset(a.get("name", "")):
                continue
            # GitHub 会为 release asset 计算摘要（形如 "sha256:..."）。
            # 这是**可信来源**：由 GitHub 生成，采集时只走直连，
            # 因此无需下载即可为**每个** release 提供校验值。
            digest = str(a.get("digest") or "").strip().lower()
            sha = digest[7:] if re.fullmatch(r"sha256:[0-9a-f]{64}", digest) else ""
            assets.append({
                "name": a.get("name", ""),
                "size": int(a.get("size") or 0),
                "sha256": sha,
                "download_url": a.get("browser_download_url", ""),
            })
        out.append({
            "tag": r.get("tag_name") or "",
            "name": r.get("name") or "",
            "body": (r.get("body") or "")[:8000],
            "published_at": r.get("published_at") or r.get("created_at") or "",
            "prerelease": bool(r.get("prerelease")),
            "html_url": r.get("html_url") or "",
            "etag": r.get("id") and str(r.get("id")) or "",
            "assets": assets,
        })
    return out


def enrich_assets_with_hap_metadata(
    releases: list[dict[str, Any]],
    *,
    token: str = "",
    progress: Callable[[str], None] | None = None,
    limit: int = 3,
) -> None:
    """为最近若干 release 里的 HAP 附件补上包内元数据与 sha256。

    只处理前 [limit] 个 release 的 HAP，避免一次采集下载过多文件。
    """
    done = 0
    for rel in releases:
        if done >= limit:
            break
        for a in rel.get("assets") or []:
            tmp = _download_to_temp(a["download_url"], token=token)
            if not tmp:
                continue
            try:
                trusted_sha = a.get("sha256") or ""
                actual_sha = _sha256_file(tmp)
                if trusted_sha and actual_sha != trusted_sha:
                    if progress:
                        progress(f"  {a['name']}: 下载内容与 GitHub 摘要不一致，已跳过")
                    continue
                if not trusted_sha:
                    # GitHub 未提供摘要时，镜像内容无法成为可信校验基准。
                    continue
                meta = parse_hap_metadata(tmp)
                a.update(meta)
                icon = extract_hap_icon(tmp)
                if icon:
                    a["_icon"] = icon
                if progress:
                    progress(
                        f"  {a['name']}: bundle={meta['bundle_name']} "
                        f"versionCode={meta['version_code']} "
                        f"versionName={meta['version_name']}"
                    )
            finally:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
        done += 1


def sync_app(repo: str, *, token: str = "", with_metadata: bool = True,
             progress: Callable[[str], None] | None = None,
             selection: dict[str, str] | None = None) -> dict[str, Any]:
    """采集单个仓库并入库。返回统计信息。"""
    meta = fetch_app_metadata(repo, token=token)
    releases = fetch_releases(repo, token=token)

    if with_metadata and releases:
        enrich_assets_with_hap_metadata(releases, token=token, progress=progress)

    if selection is None:
        existing = db.connect().execute(
            "SELECT id FROM app WHERE repo_full_name=?", (repo,)
        ).fetchone()
        selection = db.get_app_selection(existing["id"]) if existing else None
    if selection:
        selected_name = selection["asset_name"]
        selected_bundle = selection.get("bundle_name") or ""
        selected_tag = selection.get("tag") or ""
        selected_sha = selection.get("sha256") or ""
        if selected_tag and not any(
            r["tag"] == selected_tag and a["name"] == selected_name and
            (not selected_bundle or a.get("bundle_name") == selected_bundle) and
            (not selected_sha or a.get("sha256") == selected_sha)
            for r in releases for a in r.get("assets") or []
        ):
            raise CollectError("所选 HAP 已从该 GitHub Release 移除，请重新预处理")
        for release in releases:
            release["assets"] = [a for a in release.get("assets") or []
                                 if (a.get("bundle_name") == selected_bundle
                                     if selected_bundle else a["name"] == selected_name)]

    app_id = db.upsert_app(repo, sync_error="")
    selected_label = next((a.get("display_name") for r in releases
                           for a in r.get("assets") or [] if a.get("display_name")), "")
    if not selected_label:
        existing_app = db.get_app(app_id)
        selected_label = (existing_app or {}).get("display_name") or ""
    if selected_label:
        meta["display_name"] = selected_label
    n = db.replace_releases(app_id, releases)
    for release in releases:
        icon = next((asset["_icon"] for asset in release.get("assets", [])
                     if "_icon" in asset), None)
        if icon:
            db.put_app_icon(app_id, icon[0], icon[1])
            break
    db.upsert_app(repo, **meta, synced_at=int(time.time()), sync_error="")
    hap_count = sum(len(r.get("assets") or []) for r in releases)
    return {
        "app_id": app_id,
        "repo": repo,
        "releases": n,
        "hap_assets": hap_count,
    }


def sync_all(*, token: str = "", limit: int = 20,
             progress: Callable[[str], None] | None = None) -> dict[str, Any]:
    """采集需要更新的应用。"""
    rows = db.apps_needing_sync(limit=limit)
    ok, failed = 0, 0
    errors: list[str] = []
    for row in rows:
        repo = row["repo_full_name"]
        try:
            if progress:
                progress(f"采集 {repo}")
            sync_app(repo, token=token, progress=progress)
            ok += 1
        except Exception as e:  # noqa: BLE001
            failed += 1
            msg = f"{repo}: {e}"
            errors.append(msg)
            db.upsert_app(repo, sync_error=str(e)[:500])
            if progress:
                progress(f"  失败：{e}")
    db.set_meta("last_sync", time.strftime("%Y-%m-%dT%H:%M:%S"))
    db.set_meta("last_sync_ok", "1" if failed == 0 else "0")
    return {"synced": ok, "failed": failed, "errors": errors[:10]}


def probe_channels() -> dict[str, Any]:
    """探测各采集通道可达性，用于诊断与状态展示。"""
    out: dict[str, Any] = {}
    for prefix in API_MIRRORS:
        name = prefix or "direct"
        url = f"{prefix}https://api.github.com/rate_limit" if prefix else "https://api.github.com/rate_limit"
        t0 = time.time()
        try:
            _http_get(url, timeout=8)
            out[name] = {"ok": True, "ms": int((time.time() - t0) * 1000)}
        except Exception as e:  # noqa: BLE001
            out[name] = {"ok": False, "error": type(e).__name__}
    return out
