"""On-demand public README rendering with bounded, coalesced repository caching."""
from __future__ import annotations

import base64
import html
import json
import threading
import time
import urllib.error
import urllib.request
from collections import OrderedDict
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse

from . import collector

_lock = threading.Lock()
_cache: OrderedDict[str, tuple[float, dict]] = OrderedDict()
_pending: dict[str, threading.Event] = {}
MAX_SOURCE = 512 * 1024
MAX_HTML = 1024 * 1024


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


def _render(repo: str, token: str) -> dict:
    try:
        data = collector._repository_json(repo, '/readme', token=token, timeout=8)
    except Exception as error:
        if repo.startswith('gitee.com/'):
            try:
                return _gitee_document(repo)
            except Exception:
                raise error
        if isinstance(error, urllib.error.HTTPError) and error.code == 404:
            return {'found': False, 'html': '', 'source_url': collector.repository_url(repo)}
        raise
    source = base64.b64decode(data.get('content', ''), validate=False)
    if not source or len(source) > MAX_SOURCE:
        if not source:
            return {'found': False, 'html': '', 'source_url': collector.repository_url(repo)}
        raise ValueError('README 内容过大，请在仓库查看')
    if repo.startswith('gitee.com/'):
        # Gitee supplies Markdown; GitHub's passive GFM renderer supports the same markup.
        payload = json.dumps({'text': source.decode('utf-8-sig', errors='replace'), 'mode': 'gfm'}).encode()
        headers = {'User-Agent': collector.USER_AGENT, 'Content-Type': 'application/json', 'Accept': 'text/html'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request('https://api.github.com/markdown', data=payload, headers=headers)
        with urllib.request.urlopen(request, timeout=8) as response:
            rendered = response.read(MAX_HTML + 1)
    else:
        rendered = collector._http_get('https://api.github.com/repos/' + repo + '/readme',
            token=token, accept='application/vnd.github.html+json', timeout=8)
    if len(rendered) > MAX_HTML:
        raise ValueError('README 内容过大，请在仓库查看')
    page = data.get('html_url') or collector.repository_url(repo) + '/'
    raw = data.get('download_url') or page.replace('/blob/', '/raw/')
    document = _Document(page, raw)
    document.feed(rendered.decode('utf-8', errors='replace'))
    return {'found': True, 'html': ''.join(document.parts), 'source_url': page}


def get(repo: str, token: str = '') -> dict:
    # Only database repository identities accepted by the existing forge parser can reach upstream.
    canonical = collector.normalize_repo(collector.repository_url(repo))
    if not canonical or canonical != repo:
        raise ValueError('仓库地址无效')
    with _lock:
        cached = _cache.get(repo)
        if cached and time.monotonic() < cached[0]:
            _cache.move_to_end(repo)
            return cached[1]
        waiter = _pending.get(repo)
        owner = waiter is None
        if owner:
            waiter = _pending[repo] = threading.Event()
    if not owner:
        if not waiter.wait(20):
            raise TimeoutError('README 加载超时，请重试')
        with _lock:
            cached = _cache.get(repo)
            if cached and time.monotonic() < cached[0]:
                return cached[1]
        raise OSError('README 暂时无法读取，请重试')
    try:
        value = _render(repo, token)
        with _lock:
            _cache[repo] = (time.monotonic() + (3600 if value['found'] else 300), value)
            _cache.move_to_end(repo)
            while len(_cache) > 32 or sum(len(v[1].get('html', '')) for v in _cache.values()) > 8 * MAX_HTML:
                _cache.popitem(last=False)
        return value
    finally:
        with _lock:
            _pending.pop(repo, None)
            waiter.set()
