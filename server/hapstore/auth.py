"""Verify a DevEco login with the same identity endpoint used by the client.

Names supplied in request bodies are never accepted as identity. The JWT is
checked remotely for every cache miss and is not persisted or logged.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

_VERIFY_URL = "https://cn.devecostudio.huawei.com/authrouter/auth/api/jwToken/check"
_OPEN_PROFILE_URL = "https://account.cloud.huawei.com/rest.php?nsp_svc=GOpen.User.getInfo"
_cache: dict[str, tuple[float, tuple[str, str], str]] = {}
_lock = threading.Lock()


class IdentityUnavailable(Exception):
    pass


class InvalidIdentity(Exception):
    pass


def _open_profile(access_token: str, expected_user_id: str) -> tuple[str, str]:
    """Read public nickname and avatar for the verified Huawei account."""
    if not access_token:
        return "", ""
    body = urllib.parse.urlencode({"access_token": access_token,
                                   "getNickName": "1"}).encode()
    req = urllib.request.Request(_OPEN_PROFILE_URL, data=body, headers={
        "User-Agent": "HapStore/1", "Content-Type": "application/x-www-form-urlencoded",
    })
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=8) as resp:
            if resp.status != 200:
                return "", ""
            result = json.loads(resp.read(16 * 1024))
        if result.get("error"):
            return "", ""
        if str(result.get("userID") or "") != expected_user_id:
            return "", ""
        name = str(result.get("displayName") or "").strip()
        if "*" in name or "＊" in name:
            name = ""
        avatar = str(result.get("headPictureURL") or result.get("headPicUrl") or "").strip()
        parsed = urllib.parse.urlparse(avatar)
        if parsed.scheme != "https" or not parsed.netloc or len(avatar) > 2048:
            avatar = ""
        return name[:100], avatar
    except (OSError, TimeoutError, ValueError, TypeError, AttributeError):
        return "", ""


def _open_display_name(access_token: str, expected_user_id: str) -> str:
    return _open_profile(access_token, expected_user_id)[0]


def verified_avatar(jwt_token: str, access_token: str) -> str:
    """Only returns the avatar from a still-valid, server-verified login."""
    key = hashlib.sha256((jwt_token.strip() + "\0" + access_token.strip()).encode()).hexdigest()
    with _lock:
        cached = _cache.get(key)
        return cached[2] if cached and cached[0] > time.time() else ""


def verify(jwt_token: str, access_token: str = "") -> tuple[str, str]:
    """Return the verified (account id, display name)."""
    token = jwt_token.strip()
    if not token or len(token) > 8192:
        raise InvalidIdentity("请先登录华为开发者账号")
    access_token = access_token.strip()
    if len(access_token) > 4096:
        raise InvalidIdentity("登录信息已失效")
    key = hashlib.sha256((token + "\0" + access_token).encode()).hexdigest()
    with _lock:
        cached = _cache.get(key)
        if cached and cached[0] > time.time():
            return cached[1]

    req = urllib.request.Request(_VERIFY_URL, headers={
        "Accept": "application/json", "User-Agent": "HapStore/1",
        "refresh": "false", "jwtToken": token,
    })
    try:
        # The host may expose an unrelated system proxy. Identity verification
        # must use the direct TLS route, which is tested in production.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=8) as resp:
            if resp.status != 200:
                raise InvalidIdentity("登录信息已失效")
            raw = resp.read(64 * 1024)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise InvalidIdentity("登录信息已失效") from None
        raise IdentityUnavailable("账号验证服务暂不可用") from None
    except (OSError, TimeoutError):
        raise IdentityUnavailable("账号验证服务暂不可用") from None
    try:
        result = json.loads(raw)
        info = result.get("userInfo") or {}
        uid = str(info.get("userId") or "").strip()
        # DevEco's nickName may be masked. GOpen supplies the profile nickname
        # that HoKit displays; never use certificate subject/realName here.
        name, avatar = _open_profile(access_token, uid)
        name = name or uid
        if not uid or not name:
            raise ValueError("missing verified user info")
    except (ValueError, TypeError, AttributeError):
        raise InvalidIdentity("登录信息已失效") from None
    identity = (uid[:128], name[:100])
    with _lock:
        _cache[key] = (time.time() + 300, identity, avatar)
        if len(_cache) > 1024:
            _cache.clear()
    return identity
