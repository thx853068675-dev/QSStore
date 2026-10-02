#!/usr/bin/env python3
# Copyright QuietStart contributors. SPDX-License-Identifier: MIT
"""GitHub release 采集器。

两个关键设计：

1) **可信元数据与镜像下载**
   release 摘要和下载地址只从 GitHub API 直连取得。旧附件没有摘要时只允许官方
   HTTPS 直连计算摘要。镜像只用于下载已有可信摘要的 HAP；
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
import copy
import io
import json
import os
import re
import shutil
import ssl
import struct
import tempfile
import time
import threading
import urllib.error
import urllib.request
import zipfile
from typing import Any, Callable
from urllib.parse import urlparse

from PIL import Image, UnidentifiedImageError

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
    def __init__(self, message, *, retry_after=0):
        super().__init__(message)
        self.retry_after = retry_after

_github_lock = threading.Lock()
_github_cooldown: dict[str, float] = {}



def _http_get(url: str, *, token: str = "", accept: str = "application/vnd.github+json",
              timeout: int = TIMEOUT) -> bytes:
    github = urlparse(url).netloc == 'api.github.com'
    credential_key = hashlib.sha256(token.encode()).hexdigest()
    cache_key = hashlib.sha256((url + '|' + accept + '|' + credential_key).encode()).hexdigest()
    cached = None
    if github:
        with _github_lock:
            delay = int(_github_cooldown.get(credential_key, 0) - time.time())
        if delay > 0:
            raise CollectError(f'GitHub 请求配额冷却中，请在 {delay} 秒后重试', retry_after=delay)
        if db._initialized:
            cached = db.connect().execute('SELECT etag,payload FROM github_http_cache WHERE cache_key=?', (cache_key,)).fetchone()
    headers = {'User-Agent': USER_AGENT, 'Accept': accept}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    if cached:
        headers['If-None-Match'] = cached['etag']
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_CTX) as resp:
            body = resp.read(8 * 1024 * 1024 + 1)
            if len(body) > 8 * 1024 * 1024:
                raise CollectError('GitHub 元数据响应超限')
            etag = resp.headers.get('ETag', '')
            if github and etag and db._initialized:
                c = db.connect()
                with c:
                    c.execute('INSERT OR REPLACE INTO github_http_cache(cache_key,etag,payload,updated_at) VALUES (?,?,?,?)',
                              (cache_key, etag, body, int(time.time())))
                    c.execute('DELETE FROM github_http_cache WHERE cache_key IN (SELECT cache_key FROM github_http_cache ORDER BY updated_at DESC LIMIT -1 OFFSET 128)')
                    rows = c.execute('SELECT cache_key,length(payload) AS bytes FROM github_http_cache ORDER BY updated_at DESC').fetchall()
                    retained = 0
                    for row in rows:
                        retained += row['bytes']
                        if retained > 64 * 1024 * 1024:
                            c.execute('DELETE FROM github_http_cache WHERE cache_key=?', (row['cache_key'],))
            return body
    except urllib.error.HTTPError as error:
        if error.code == 304 and cached:
            return cached['payload']
        if github and (error.code == 429 or (error.code == 403 and error.headers.get('X-RateLimit-Remaining') == '0')):
            now = time.time()
            try:
                delay = max(60, int(error.headers.get('Retry-After', '0')),
                            int(error.headers.get('X-RateLimit-Reset', '0')) - int(now))
            except ValueError:
                delay = 60
            delay = min(delay, 3600)
            with _github_lock:
                if len(_github_cooldown) >= 16:
                    _github_cooldown.clear()
                _github_cooldown[credential_key] = now + delay
            raise CollectError(f'GitHub 请求配额已用尽，{delay} 秒后自动重试', retry_after=delay) from error
        raise


def _try_chain(path: str, *, token: str = "", timeout: int = TIMEOUT) -> tuple[bytes, str]:
    """摘要和下载地址只能取自 GitHub；不能让第三方代理签发校验值。"""
    try:
        return _http_get(f"https://api.github.com{path}", token=token, timeout=timeout), "direct"
    except CollectError:
        raise
    except Exception as e:
        raise CollectError(f"GitHub API 直连失败（{path}）：{e}") from e


def _json(path: str, *, token: str = "", timeout: int = TIMEOUT) -> Any:
    body, _ = _try_chain(path, token=token, timeout=timeout)
    return json.loads(body.decode("utf-8", "replace"))


# ───────────────────────── HAP 内嵌元数据 ─────────────────────────


MAX_MANIFEST_BYTES = 4 * 1024 * 1024

def validate_hap_manifests(archive: zipfile.ZipFile) -> None:
    for name in ('pack.info', 'module.json'):
        matches = [row for row in archive.infolist() if row.filename == name]
        if len(matches) > 1 or (matches and (matches[0].file_size > MAX_MANIFEST_BYTES or matches[0].flag_bits & 1)):
            raise CollectError('安装包清单重复、加密或超限')


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
            validate_hap_manifests(z)
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
    except CollectError:
        raise
    except zipfile.BadZipFile:
        return out
    except Exception:
        return out
    return out


def _resource_string(data: bytes, resource_id: int, max_len: int = 100) -> str:
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
        if len(data) > 4 * 1024 * 1024:
            return ""
        if u32(128) != len(data):
            return ""
        key_count = u32(132)
        if key_count > 256:
            return ""
        if data.startswith(b"Restool 6."):
            # Restool 6 uses a compact IDSS table per resource configuration.
            # Each table maps ID -> entry offset; the entry stores a bounded
            # UTF-8 value directly after its type and ID fields.
            pos = 136
            sections = []
            for _ in range(key_count):
                if data[pos:pos + 4] != b"KEYS":
                    return ""
                sections.append(u32(pos + 4))
                config_count = u32(pos + 8)
                if config_count > 64:
                    return ""
                pos += 12 + config_count * 8
                if pos > len(data):
                    return ""
            for section in sections:
                if data[section:section + 4] != b"IDSS":
                    continue
                count = u32(section + 4)
                if count > 10000 or section + 8 + count * 8 > len(data):
                    continue
                for n in range(count):
                    rid = u32(section + 8 + n * 8)
                    if rid != resource_id:
                        continue
                    offset = u32(section + 12 + n * 8)
                    if u32(offset + 8) != rid or offset + 14 > len(data):
                        return ""
                    size = struct.unpack_from("<H", data, offset + 12)[0]
                    if size == 0 or size > 512 or offset + 14 + size > len(data):
                        return ""
                    return data[offset + 14:offset + 14 + size].rstrip(b"\0").decode("utf-8")[:max_len]
            return ""
        if not data.startswith(b"RestoolV2"):
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
                        return value[:max_len]
                    if value and not fallback:
                        fallback = value[:max_len]
                return fallback
    except (ValueError, UnicodeError, struct.error):
        return ""
    return ""


def _icon_entry(archive: zipfile.ZipFile, reference: str, index: bytes = b"") -> str:
    """Resolve a manifest resource reference to its exact ZIP member."""
    value = reference.strip()
    if value.startswith("$media:"):
        value = value[7:]
    if value.isdecimal() and index:
        value = _resource_string(index, int(value), 512)
    if value.startswith("entry/resources/"):
        value = value[len("entry/"):]
    if value.startswith("resources/"):
        return value if "/media/" in value and value in archive.namelist() else ""
    if not value or "/" in value or "\\" in value or value.startswith("."):
        return ""
    base = value.rsplit(".", 1)[0]
    matches = [name for name in archive.namelist()
               if name.startswith("resources/") and "/media/" in name and
               (name.rsplit("/", 1)[-1] == value or
                name.rsplit("/", 1)[-1].rsplit(".", 1)[0].split("@", 1)[0] == base)]
    if not matches:
        return ""
    return min(matches, key=lambda name: (not name.startswith("resources/base/media/"), name))


def _icon_image(archive: zipfile.ZipFile, name: str) -> tuple[str, bytes, Image.Image] | None:
    if not name or not name.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
        return None
    entry = archive.getinfo(name)
    if not 100 <= entry.file_size <= 1024 * 1024:
        return None
    data = archive.read(entry)
    try:
        image = Image.open(io.BytesIO(data))
        if not (32 <= image.width <= 2048 and 32 <= image.height <= 2048):
            return None
        image.load()
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError, ValueError):
        return None
    mime = {"PNG": "image/png", "JPEG": "image/jpeg", "WEBP": "image/webp"}.get(image.format)
    return (mime, data, image) if mime else None


def extract_hap_icon(path: str) -> tuple[str, bytes] | None:
    """Read the launcher icon declared by module.json, including layered images.

    The app-level icon may be a template placeholder while the launcher ability
    declares the icon users actually see after installation. Never guess from
    filenames: startWindowIcon and toolbar icons are unrelated resources.
    """
    try:
        with zipfile.ZipFile(path) as archive:
            module = archive.getinfo("module.json")
            if module.file_size > 1024 * 1024:
                return None
            manifest = json.loads(archive.read(module))
            app = manifest.get("app") or {}
            module_info = manifest.get("module") or {}
            abilities = [a for a in module_info.get("abilities") or [] if isinstance(a, dict)]
            main_name = module_info.get("mainElement") or ""
            def launcher_rank(ability: dict[str, Any]) -> tuple[int, int]:
                skills = ability.get("skills") or []
                is_home = any(
                    "entity.system.home" in (skill.get("entities") or []) or
                    "action.system.home" in (skill.get("actions") or [])
                    for skill in skills if isinstance(skill, dict)
                )
                return (0 if is_home else 1, 0 if ability.get("name") == main_name else 1)
            candidates = sorted(abilities, key=launcher_rank) + [app]
            index = b""
            if "resources.index" in archive.namelist():
                entry = archive.getinfo("resources.index")
                if entry.file_size <= 4 * 1024 * 1024:
                    index = archive.read(entry)
            for source in candidates:
                reference = source.get("icon") or ""
                if isinstance(reference, dict):
                    reference = reference.get("name") or ""
                if not isinstance(reference, str):
                    continue
                # The compiled iconId identifies the exact resource even if a
                # configuration-specific source renamed its file.
                icon_id = source.get("iconId")
                resolved = _icon_entry(archive, str(icon_id), index) if type(icon_id) is int else ""
                name = resolved or _icon_entry(archive, reference, index)
                if not name:
                    continue
                try:
                    if name.endswith(".json"):
                        entry = archive.getinfo(name)
                        if entry.file_size > 16 * 1024:
                            continue
                        layers = (json.loads(archive.read(entry)).get("layered-image") or {})
                        background = _icon_image(archive, _icon_entry(archive, str(layers.get("background") or ""), index))
                        foreground = _icon_image(archive, _icon_entry(archive, str(layers.get("foreground") or ""), index))
                        if not background or not foreground or background[2].size != foreground[2].size:
                            continue
                        composed = Image.alpha_composite(background[2].convert("RGBA"), foreground[2].convert("RGBA"))
                        output = io.BytesIO()
                        composed.save(output, format="PNG", optimize=True)
                        data = output.getvalue()
                        if len(data) <= 1024 * 1024:
                            return "image/png", data
                    else:
                        image = _icon_image(archive, name)
                        if image:
                            return image[0], image[1]
                except (KeyError, ValueError, TypeError, json.JSONDecodeError):
                    continue
            return None
    except (OSError, zipfile.BadZipFile, KeyError, RuntimeError, ValueError, TypeError, json.JSONDecodeError):
        return None


_CATEGORY_KEYWORDS = (
    ("游戏", ("game", "gaming", "游戏")),
    # 顺序即优先级：`classify_repo` 先命中先返回，所以更具体的类型排在更泛的
    # 前面（「阅读」先于「工具」，「影音」先于「工具」）。每个词都在上架的
    # SUBMIT_CATEGORIES 白名单里，命中后可以直接提交，不需要用户改。
    ("社交通讯", ("chat", "messenger", "social", "mail", "email",
                  "聊天", "社交", "通讯", "邮件", "短信")),
    ("影音", ("music", "audio", "video", "player", "media", "podcast", "radio",
              "音乐", "音频", "视频", "播放", "影视", "播客", "电台")),
    ("摄影录像", ("camera", "photo", "gallery", "picture", "scan",
                  "相机", "摄影", "拍照", "相册", "图片", "扫描")),
    ("阅读", ("reader", "reading", "ebook", "book", "novel", "comic", "rss",
              "阅读", "电子书", "小说", "漫画")),
    ("新闻资讯", ("news", "feed", "资讯", "新闻", "头条")),
    ("开发工具", ("developer", "development", "ide", "sdk", "debug", "compiler",
                  "git", "api", "编程", "开发", "调试", "编译")),
    ("办公", ("office", "document", "spreadsheet", "slides", "pdf", "wps",
              "办公", "文档", "表格", "演示", "幻灯片")),
    ("学习", ("learn", "learning", "study", "course", "exam", "dictionary", "language",
              "tutor", "quiz", "学习", "课程", "考试", "词典", "背单词", "题库")),
    ("效率", ("productivity", "notes", "todo", "task", "calendar", "reminder", "gtd",
              "笔记", "待办", "日程", "提醒", "效率", "清单")),
    ("安全隐私", ("security", "vpn", "password", "encrypt", "privacy", "firewall",
                  "安全", "加密", "密码", "隐私", "防护")),
    ("系统工具", ("system", "launcher", "settings", "kernel", "terminal", "shell",
                  "系统", "启动器", "设置", "终端")),
    ("出行导航", ("navigation", "transit", "travel", "taxi", "flight", "地图",
                  "导航", "公交", "出行", "旅行", "打车", "航班")),
    ("购物", ("shopping", "shop", "ecommerce", "mall", "coupon", "购物", "商城", "优惠")),
    ("财务", ("finance", "bank", "wallet", "payment", "accounting", "stock", "budget",
              "财务", "记账", "银行", "钱包", "支付", "股票", "账本")),
    ("医疗健康", ("medical", "doctor", "hospital", "medicine", "clinic", "symptom",
                  "医疗", "医生", "医院", "用药", "问诊", "症状")),
    ("健康运动", ("fitness", "workout", "sport", "health", "sleep", "step",
                  "健身", "运动", "锻炼", "睡眠", "步数", "跑步", "健康")),
    ("美食菜谱", ("recipe", "cook", "food", "restaurant", "菜谱", "做饭", "美食", "餐厅")),
    ("育儿母婴", ("baby", "parenting", "pregnancy", "育儿", "母婴", "宝宝", "孕期")),
    ("儿童", ("kids", "children", "toy", "儿童", "少儿", "玩具")),
    ("无障碍", ("accessibility", "blind", "无障碍", "读屏", "视障")),
    ("政务民生", ("government", "citizen", "政务", "民生", "社保", "公积金")),
    ("企业应用", ("enterprise", "erp", "crm", "oa", "企业", "商务", "考勤")),
    ("个性化", ("theme", "wallpaper", "widget", "font", "主题", "壁纸",
                "小组件", "图标包", "字体")),
    ("居家生活", ("smart home", "smarthome", "appliance", "家居",
                  "智能家居", "家电", "生活")),
    ("实用工具", ("utility", "utilities", "toolbox", "calculator", "converter",
                  "measure", "工具", "计算器", "换算", "测量")),
    ("教育", ("education", "school", "university", "教育", "学校", "校园")),
    ("工具", ("utility", "utilities", "tools", "工具")),
    ("生活", ("life", "lifestyle", "daily", "生活", "日常")),
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


def _download_to_temp(url: str, *, token: str = "", direct_only: bool = False) -> str | None:
    """把 HAP 下到临时文件用于解析。失败返回 None（不阻断采集）。

    重要：**超限截断的文件必须丢弃**。超限时若把已写入的临时文件当完整包返回，
    随后按它算出的 sha256 是错的，一旦入库就会毒害客户端的完整性校验 ——
    客户端会拿这个错误哈希去比对，从而拒掉本来正常的包（或反之放行被截断的包）。
    """
    if direct_only:
        parsed = urlparse(url)
        if parsed.scheme != 'https' or parsed.hostname != 'github.com' or '/releases/download/' not in parsed.path:
            return None
    for prefix in (('',) if direct_only else API_MIRRORS):
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
    return name.lower().endswith((".hap", ".app", ".zip"))


# ───────────────────────── 采集主流程 ─────────────────────────


def fetch_app_metadata(repo: str, *, token: str = "", timeout: int = TIMEOUT) -> dict[str, Any]:
    """拉取仓库基础信息。"""
    data = _json(f"/repos/{repo}", token=token, timeout=timeout)
    return {
        "display_name": data.get("name") or repo.split("/")[-1],
        "description": data.get("description") or "",
        "summary": (data.get("description") or "")[:120],
        "stars": int(data.get("stargazers_count") or 0),
        "homepage": data.get("homepage") or "",
        "license": ((data.get("license") or {}) or {}).get("spdx_id") or "",
        "tags_json": json.dumps(data.get("topics") or [], ensure_ascii=False),
        "category": classify_repo(data.get("topics") or [], data.get("description") or ""),
        # A repository owner's avatar is not the application's icon.
        "icon_url": "",
    }


def fetch_releases(repo: str, *, token: str = "", limit: int = 300,
                   timeout: int = TIMEOUT) -> list[dict[str, Any]]:
    """分页取发布元数据；只解析有限安装包，完整分页失败时不提交残缺快照。"""
    limit = max(1, min(int(limit), 1000))
    page_size = min(limit, 100)
    raw = []
    for page in range(1, (limit + page_size - 1) // page_size + 1):
        suffix = '' if page == 1 else f'&page={page}'
        rows = _json(f"/repos/{repo}/releases?per_page={page_size}{suffix}", token=token, timeout=timeout)
        if not isinstance(rows, list):
            raise CollectError('GitHub 版本列表格式异常，保留原有版本')
        raw.extend(rows)
        if len(rows) < page_size:
            break
    else:
        # 不能让数据库把未抓到的历史版本当成上游删除。
        raise CollectError('GitHub 版本列表超过采集上限，保留原有版本')
    out: list[dict[str, Any]] = []
    for r in raw:
        if r.get('draft'):
            continue
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
    return sorted(out, key=lambda r: r["published_at"], reverse=True)


def metadata_scan_order(releases: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """在原有三条解析预算内，同时覆盖最新正式包和预览包。"""
    leading = []
    for preview in (False, True):
        row = next((r for r in releases if bool(r.get('prerelease')) == preview and r.get('assets')), None)
        if row is not None:
            leading.append(row)
    remaining = [r for r in releases if not any(r is item for item in leading)]
    return leading + [r for r in remaining if r.get('prerelease')] + [r for r in remaining if not r.get('prerelease')]


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
    from . import artifact_cache
    done = 0
    for rel in releases:
        if done >= limit:
            break
        expanded = []
        for a in rel.get("assets") or []:
            if a['name'].lower().endswith(('.app', '.zip')) or '#qingqi-package=' in a['download_url']:
                from .package_archive import scan_asset
                try: expanded.extend(scan_asset(a, token))
                except CollectError:
                    if not a['name'].lower().endswith('.zip'): expanded.append(a)
                continue
            expanded.append(a)
            cached = artifact_cache.get(a.get('sha256', ''), 'hap')
            if cached is not None:
                a.update(cached[0])
                continue
            trusted_sha = a.get("sha256") or ""
            # GitHub 的旧附件可能没有 digest；只能从官方 HTTPS 下载并计算，
            # 不能用镜像内容补成可信校验值。
            tmp = _download_to_temp(a["download_url"], token=token, direct_only=not bool(trusted_sha))
            if not tmp:
                continue
            try:
                actual_sha = _sha256_file(tmp)
                if trusted_sha and actual_sha != trusted_sha:
                    if progress:
                        progress(f"  {a['name']}: 下载内容与 GitHub 摘要不一致，已跳过")
                    continue
                if not trusted_sha:
                    trusted_sha = actual_sha
                    a['sha256'] = actual_sha
                meta = parse_hap_metadata(tmp)
                a.update(meta)
                a["_icon_checked"] = True
                icon = extract_hap_icon(tmp)
                if icon:
                    a["_icon"] = icon
                artifact_cache.put(trusted_sha, 'hap', [a])
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
        rel['assets'] = expanded
        done += 1


def sync_app(repo: str, *, token: str = "", with_metadata: bool = True,
             progress: Callable[[str], None] | None = None,
             selection: dict[str, Any] | None = None,
             snapshot: dict[str, Any] | None = None,
             generation: int | None = None) -> dict[str, Any]:
    """采集单个仓库并入库。返回统计信息。"""
    explicit_selection = selection is not None
    meta = copy.deepcopy(snapshot["metadata"]) if snapshot else fetch_app_metadata(repo, token=token)
    releases = copy.deepcopy(snapshot["releases"]) if snapshot else fetch_releases(repo, token=token)

    if with_metadata and releases:
        scan_releases = metadata_scan_order(releases)
        if generation is not None and selection:
            selected = next((r for r in releases if r["tag"] == selection.get("tag")), None)
            if selected:
                target = dict(selected)
                target["assets"] = [a for a in selected.get("assets", [])
                                    if a['name'] in [item['asset_name'] for item in
                                        (selection.get('assets') or [selection])]]
                # The selected HAP comes first, including a legacy draft whose
                # Release is no longer in GitHub's first three entries.
                scan_releases = [target] + metadata_scan_order([r for r in releases if r is not selected and r.get("assets")])
        enrich_assets_with_hap_metadata(scan_releases, token=token, progress=progress)
        if scan_releases is not releases and scan_releases:
            for original in releases:
                if original['tag'] == scan_releases[0]['tag']:
                    replaced = {a['name'] for a in scan_releases[0]['assets']}
                    original['assets'] = scan_releases[0]['assets'] + [a for a in original['assets'] if a['name'] not in replaced]
                    break

    # A temporary download failure must not erase metadata already verified
    # against the same GitHub digest. This also keeps older releases usable:
    # the normal scan only downloads the first few releases each run.
    existing_row = db.connect().execute(
        "SELECT id FROM app WHERE repo_full_name=?", (repo,)
    ).fetchone()
    if existing_row:
        for release in releases:
            for asset in release.get("assets") or []:
                if asset.get("bundle_name") or not asset.get("sha256"):
                    continue
                previous = db.connect().execute(
                    """SELECT a.bundle_name,a.version_code,a.version_name,a.min_api
                       FROM asset a JOIN release r ON r.id=a.release_id
                       WHERE r.app_id=? AND r.tag=? AND a.name=? AND a.sha256=?""",
                    (existing_row["id"], release["tag"], asset["name"], asset["sha256"]),
                ).fetchone()
                if previous:
                    for field in ("bundle_name", "version_code", "version_name", "min_api"):
                        asset[field] = previous[field]

    if selection is None:
        selection = db.get_app_selection(existing_row["id"]) if existing_row else None
    if selection:
        selection = dict(selection)
        selections = selection.get('assets') or [selection]
        for chosen in selections:
            name, bundle = chosen['asset_name'], chosen.get('bundle_name', '')
            tag, sha = chosen.get('tag', ''), chosen.get('sha256', '')
            if not bundle:
                bundle = next((a.get('bundle_name', '') for r in releases if not tag or r['tag'] == tag
                    for a in r.get('assets', []) if a['name'] == name and (not sha or a.get('sha256') == sha)), '')
                chosen['bundle_name'] = bundle
            if generation is not None and not bundle:
                raise CollectError('所选安装包的应用身份尚未解析成功，后台将重试')
            if (generation is not None or explicit_selection) and tag and not any(r['tag'] == tag and a['name'] == name and
                (not bundle or a.get('bundle_name') == bundle) and (not sha or a.get('sha256') == sha)
                for r in releases for a in r.get('assets', [])):
                raise CollectError('所选安装包已从 Release 移除，请重新检查')
        selection['assets'] = selections
        selection['bundle_name'] = selections[0].get('bundle_name', '')
        for release in releases:
            keep = []
            for chosen in selections:
                matching = [a for a in release.get('assets', []) if
                    (a.get('bundle_name') == chosen.get('bundle_name') if chosen.get('bundle_name')
                     else a['name'] == chosen['asset_name'])]
                preferred = [a for a in matching if a['name'] == chosen['asset_name']]
                for asset in preferred or matching:
                    if not any(old['name'] == asset['name'] for old in keep): keep.append(asset)
            if release.get('prerelease') and not keep:
                # 同一仓库的旧预发布可能改过包名。保留已解析的实际身份；
                # 客户端按包名关联安装状态，不把不同包名的包当成覆盖更新。
                keep = [a for a in release.get('assets', []) if a.get('bundle_name') and a.get('version_code', 0) > 0]
            release['assets'] = keep

    presentation_releases = [r for r in releases if not r.get("prerelease")] or releases
    selected_label = next((a.get("display_name") for r in presentation_releases
                           for a in r.get("assets") or [] if a.get("display_name")), "")
    if not selected_label:
        existing_app = db.get_app(existing_row["id"]) if existing_row else None
        selected_label = (existing_app or {}).get("display_name") or ""
    if selected_label:
        meta["display_name"] = selected_label
    app_id, n, applied = db.apply_catalog_snapshot(repo, meta, releases, generation,
        (selection or {}).get("bundle_name", ""), (snapshot or {}).get("fetched_at"),
        (selection or {}).get("assets"))
    hap_count = sum(len(r.get("assets") or []) for r in releases)
    return {
        "app_id": app_id,
        "repo": repo,
        "releases": n,
        "hap_assets": hap_count,
        "applied": applied,
    }


def sync_max_age_seconds() -> int:
    """多久没采过的应用算「该重采了」。

    **这是采集新鲜度的真正开关，不是 `HAPSTORE_SYNC_INTERVAL`。** 后台循环按
    `SYNC_INTERVAL` 唤醒，但每次只采 `apps_needing_sync()` 挑出来的应用，而那个
    函数原来硬编码 6 小时 —— 于是「每 30 分钟醒一次、却只采超过 6 小时没采的」，
    改 `SYNC_INTERVAL` 完全没有效果。现在这个阈值可以配。

    取值要和唤醒间隔匹配：阈值明显大于间隔，才会每轮都有活干。
    """
    raw = os.environ.get("HAPSTORE_SYNC_MAX_AGE", "")
    if raw:
        try:
            value = int(raw)
            if value > 0:
                return value
        except ValueError:
            print(f"sync: 忽略无效的 HAPSTORE_SYNC_MAX_AGE={raw!r}", flush=True)
    # 默认 1 小时。原来写死 6 小时：配合 30 分钟的唤醒间隔，等于「醒两次才轮到
    # 一个应用重采」，刚发布的版本最坏要等 6 小时才在客户端可见。
    return 3600


def sync_all(*, token: str = "", limit: int = 20,
             progress: Callable[[str], None] | None = None) -> dict[str, Any]:
    """采集需要更新的应用。"""
    rows = db.apps_needing_sync(limit=limit,
                                max_age_seconds=sync_max_age_seconds())
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
