"""Fresh public README retrieval, local rendering and in-flight request coalescing."""
from __future__ import annotations

import base64
import html
import json
import posixpath
import re
import threading
import time
import urllib.error
import urllib.request
from html.parser import HTMLParser
from urllib.parse import quote, unquote, urljoin, urlparse

from . import collector
import mistune

_lock = threading.Lock()
_workers = threading.BoundedSemaphore(4)
MAX_SOURCE = 512 * 1024
MAX_HTML = 1024 * 1024
READ_WAIT_SECONDS = 8


class _Pending:
    def __init__(self):
        self.done = threading.Event()
        self.value = None
        self.error = None


_pending: dict[tuple[str, str], _Pending] = {}


def _repository_json(repo: str, suffix: str, *, token: str = '', timeout: float = 3):
    # README presentation deliberately bypasses collector ETags/payload caches.
    # Every completed view revalidates against the official repository itself.
    gitee = repo.startswith('gitee.com/')
    url = ('https://gitee.com/api/v5/repos/' + repo.removeprefix('gitee.com/') if gitee
           else 'https://api.github.com/repos/' + repo) + suffix
    headers = {'User-Agent': collector.USER_AGENT, 'Accept': 'application/json' if gitee else 'application/vnd.github+json',
               'Cache-Control': 'no-cache'}
    if token and not gitee:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(url, headers=headers)
    response = (urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=timeout)
                if gitee else urllib.request.urlopen(request, timeout=timeout))
    with response:
        payload = response.read(2 * MAX_HTML + 1)
    if len(payload) > 2 * MAX_HTML:
        raise ValueError('README 内容过大，请在仓库查看')
    return json.loads(payload)


class _Document(HTMLParser):
    """Retain passive Markdown HTML; resolve image and document links independently."""
    tags = set('p div span h1 h2 h3 h4 h5 h6 strong b em i s del code pre blockquote ul ol li '
               'table thead tbody tr th td a img br hr details summary kbd sup sub input'.split())
    void = {'img', 'br', 'hr', 'input'}

    def __init__(self, page: str, raw: str):
        super().__init__(convert_charrefs=True)
        self.page, self.raw, self.parts = page, raw, []
        self.blocked = 0

    def handle_starttag(self, tag, attrs):
        if tag in {'script', 'style', 'iframe', 'object', 'svg'}:
            self.blocked += 1
            return
        if self.blocked or tag not in self.tags:
            return
        safe = []
        for key, value in attrs:
            value = value or ''
            if key in {'href', 'src'}:
                if (key == 'src' and tag != 'img') or (key == 'href' and tag != 'a'):
                    continue
                value = urljoin(self.raw if key == 'src' else self.page, value)
                if urlparse(value).scheme not in {'https', 'http'}:
                    continue
            elif key in {'alt', 'title', 'align', 'colspan', 'rowspan'}:
                pass
            elif tag == 'input' and key in {'type', 'checked'}:
                if key == 'type' and value != 'checkbox':
                    continue
            else:
                continue
            safe.append(f' {key}="{html.escape(value, quote=True)}"')
        if tag == 'input':
            safe.append(' disabled')
        self.parts.append('<' + tag + ''.join(safe) + '>')

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if tag in {'script', 'style', 'iframe', 'object', 'svg'}:
            self.blocked = max(0, self.blocked - 1)
        elif not self.blocked and tag in self.tags and tag not in self.void:
            self.parts.append('</' + tag + '>')

    def handle_data(self, text):
        if not self.blocked:
            self.parts.append(html.escape(text))


class _GiteePage(HTMLParser):
    """The public repository page exposes the same rendered README when its API is restricted."""
    def __init__(self, repo):
        super().__init__(convert_charrefs=True)
        self.depth, self.done, self.parts = 0, False, []
        self.source = collector.repository_url(repo) + '/'

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        href = values.get('href', '')
        if tag == 'a' and '/blob/' in href and href.lower().endswith('/readme.md'):
            self.source = urljoin('https://gitee.com', href)
        if not self.depth and not self.done and tag == 'div' and 'markdown-body' in values.get('class', '').split():
            self.depth = 1
        elif self.depth and tag == 'div':
            self.depth += 1
        if self.depth:
            self.parts.append(self.get_starttag_text())

    def handle_endtag(self, tag):
        if self.depth:
            self.parts.append('</' + tag + '>')
            if tag == 'div':
                self.depth -= 1
                self.done = not self.depth

    def handle_data(self, text):
        if self.depth:
            self.parts.append(html.escape(text))


def _gitee_document(repo: str) -> dict:
    request = urllib.request.Request(collector.repository_url(repo),
        headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'text/html'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=8) as response:
        page = response.read(MAX_HTML + 1)
    if len(page) > MAX_HTML:
        raise ValueError('README 内容过大，请在仓库查看')
    parser = _GiteePage(repo)
    parser.feed(page.decode('utf-8', errors='replace'))
    document = _Document(parser.source, parser.source.replace('/blob/', '/raw/'))
    document.feed(''.join(parser.parts))
    body = ''.join(document.parts)
    return {'found': bool(body), 'html': body, 'source_url': parser.source}


def _language(value: str) -> str:
    value = value.lower().replace('_', '-')
    return 'zh' if value == 'zh' or value.startswith('zh-') else 'en' if value == 'en' or value.startswith('en-') else ''


def _locale_rank(path: str, language: str) -> int:
    """Prefer Simplified Chinese, then generic Chinese; match only README files."""
    parts = path.lower().replace('_', '-').split('/')
    stem = re.sub(r'\.(?:md|markdown|rst|txt)$', '', parts[-1])
    if not stem.startswith('readme'):
        return 100
    locale = stem[6:].strip('.- ') or (parts[-2] if len(parts) > 1 else '')
    locales = (['zh-cn', 'zh-hans', 'zh-hans-cn', 'zh', 'cn', 'chinese', '中文', 'chs', 'zh-tw', 'zh-hant', 'cht']
               if language == 'zh' else ['en', 'en-us', 'en-gb', 'english'])
    return locales.index(locale) if locale in locales else 100


def _localized(repo: str, token: str, language: str, default: dict, deadline: float | None = None) -> dict:
    default_path = str(default.get('path') or 'README.md')
    default_rank = _locale_rank(default_path, language)
    if default_rank == 0:
        return default

    def budget():
        remaining = 5 if deadline is None else min(3, deadline - time.monotonic())
        if remaining <= 0.1: raise TimeoutError('README localization deadline')
        return remaining

    tried: set[str] = set()

    def choose(paths: set[str], limit: int) -> dict | None:
        for path in sorted(paths - tried, key=lambda value: (_locale_rank(value, language), value))[:limit]:
            tried.add(path)
            try:
                value = _repository_json(repo, '/contents/' + quote(path, safe='/'), token=token, timeout=budget())
                if isinstance(value, dict) and int(value.get('size') or 0) <= MAX_SOURCE:
                    content = base64.b64decode(value.get('content', ''))
                    if 0 < len(content) <= MAX_SOURCE and content.strip():
                        return value
            except Exception:
                continue
        return None

    # Language links can point into docs/ without requiring a recursive repository scan.
    candidates: set[str] = set()
    try:
        markdown = base64.b64decode(default.get('content', '')).decode('utf-8-sig', errors='replace')[:MAX_SOURCE]
        links = re.findall(r'\]\(\s*<?([^\s)>]+)', markdown)
        links += re.findall(r'^\s{0,3}\[[^\]\n]+\]:\s*<?([^\s>]+)', markdown, flags=re.M)
        links += re.findall(r'''\bhref\s*=\s*["']([^"']+)["']''', markdown, flags=re.I)
        for target in links:
            target = html.unescape(target)
            parsed = urlparse(target)
            if parsed.scheme or parsed.netloc or target.startswith('/'):
                continue
            path = posixpath.normpath(posixpath.join(posixpath.dirname(default_path), unquote(parsed.path)))
            if not path.startswith(('/', '../')) and path != '..' and _locale_rank(path, language) < default_rank:
                candidates.add(path)
    except (ValueError, TypeError):
        pass
    linked = choose(candidates, 1)
    if linked is not None:
        return linked

    # A stale language link must not mask a valid translated file in the root.
    try:
        listing = _repository_json(repo, '/contents', token=token, timeout=budget())
    except Exception:
        listing = []
    if isinstance(listing, list):
        for item in listing[:1000]:
            if isinstance(item, dict) and item.get('type') == 'file':
                path = str(item.get('path') or item.get('name') or '')
                if _locale_rank(path, language) < default_rank:
                    candidates.add(path)
    return choose(candidates, 2) or default


def _render(repo: str, token: str, language: str = '') -> dict:
    deadline = time.monotonic() + 8
    error = None
    try:
        data = _repository_json(repo, '/readme', token=token, timeout=3)
    except Exception as exc:
        error, data = exc, {}
    if language:
        data = _localized(repo, token, language, data, deadline)
        if data:
            error = None
    if error is not None:
        if repo.startswith('gitee.com/'):
            try:
                return _gitee_document(repo)
            except Exception:
                raise error
        if isinstance(error, urllib.error.HTTPError) and error.code == 404:
            return {'found': False, 'html': '', 'source_url': collector.repository_url(repo)}
        raise error
    source = base64.b64decode(data.get('content', ''), validate=False)
    if not source or len(source) > MAX_SOURCE:
        if not source:
            return {'found': False, 'html': '', 'source_url': collector.repository_url(repo)}
        raise ValueError('README 内容过大，请在仓库查看')
    # The source is already present. Rendering it locally avoids another slow
    # cross-border API call, and avoids sending Gitee content to GitHub.
    markdown = mistune.create_markdown(escape=False, plugins=['table', 'strikethrough', 'task_lists', 'url'])
    rendered = markdown(source.decode('utf-8-sig', errors='replace')).encode('utf-8')
    if len(rendered) > MAX_HTML:
        raise ValueError('README 内容过大，请在仓库查看')
    page = data.get('html_url') or collector.repository_url(repo) + '/'
    raw = data.get('download_url') or page.replace('/blob/', '/raw/')
    document = _Document(page, raw)
    document.feed(rendered.decode('utf-8', errors='replace'))
    return {'found': True, 'html': ''.join(document.parts), 'source_url': page}



def _fetch(repo, token, language, key, waiter):
    try:
        waiter.value = _render(repo, token, language)
    except Exception as error:
        waiter.error = error
    finally:
        with _lock:
            if _pending.get(key) is waiter:
                _pending.pop(key, None)
            waiter.done.set()
        _workers.release()


def get(repo: str, token: str = '', language: str = '') -> dict:
    canonical = collector.normalize_repo(collector.repository_url(repo))
    if not canonical or canonical != repo:
        raise ValueError('仓库地址无效')
    language = _language(language)
    key = (repo, language)
    with _lock:
        waiter = _pending.get(key)
        if waiter is None:
            if not _workers.acquire(blocking=False):
                raise OSError('README 暂时无法读取，请稍后重试')
            waiter = _pending[key] = _Pending()
            try:
                threading.Thread(target=_fetch, args=(repo, token, language, key, waiter),
                    daemon=True, name='readme-fetch').start()
            except BaseException:
                _pending.pop(key, None)
                _workers.release()
                raise
    if not waiter.done.wait(READ_WAIT_SECONDS):
        raise TimeoutError('README 暂时无法读取，请重试')
    if waiter.error is not None:
        raise waiter.error
    return waiter.value
