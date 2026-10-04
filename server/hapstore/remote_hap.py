"""Read large HAP manifests from official GitHub byte ranges, with a hard budget.

Never read an ignored Range response as a full package, and never use mirrors:
partial bytes cannot be compared with the upstream whole-file SHA-256.
"""
from __future__ import annotations
import io
import re
import ssl
import time
import urllib.request
from urllib.parse import urlparse

MAX_BYTES = 8 * 1024 * 1024
MAX_REQUESTS = 48
MAX_SECONDS = 30
OFFICIAL_HOSTS = {'api.github.com', 'release-assets.githubusercontent.com',
                  'objects.githubusercontent.com', 'github.com'}


class OfficialRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urlparse(newurl)
        if parsed.scheme != 'https' or parsed.hostname not in OFFICIAL_HOSTS:
            raise OSError('GitHub asset redirected outside official hosts')
        next_request = super().redirect_request(req, fp, code, msg, headers, newurl)
        if next_request and parsed.hostname != 'api.github.com':
            next_request.remove_header('Authorization')
        return next_request


class RemoteHap(io.RawIOBase):
    def __init__(self, api_url, size, token=''):
        parsed = urlparse(api_url)
        if (parsed.scheme != 'https' or parsed.hostname != 'api.github.com'
                or not re.fullmatch(r'/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/assets/[0-9]+', parsed.path)
                or parsed.query or parsed.fragment or not 0 < size <= 8 * 1024 ** 3):
            raise OSError('Invalid official GitHub asset')
        self.url, self.size, self.token = api_url, size, token
        self.position = self.transferred = self.requests = 0
        self.deadline = time.monotonic() + MAX_SECONDS
        self.etag = ''
        self.read_failed = False
        self.blocks = []
        self.opener = urllib.request.build_opener(OfficialRedirects(),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()))

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=io.SEEK_SET):
        position = offset if whence == io.SEEK_SET else (
            self.position + offset if whence == io.SEEK_CUR else self.size + offset)
        if whence not in (io.SEEK_SET, io.SEEK_CUR, io.SEEK_END) or position < 0:
            raise OSError('Invalid remote archive position')
        self.position = position
        return position

    def read(self, count=-1):
        try:
            return self._read(count)
        except OSError:
            # Icon decoders intentionally tolerate invalid/unsupported images.
            # Preserve failures from the range reader separately from those.
            self.read_failed = True
            raise

    def _read(self, count=-1):
        start = self.position
        count = min(self.size - start, self.size if count < 0 else count)
        if count <= 0:
            return b''
        for offset, data in self.blocks:
            if offset <= start and start + count <= offset + len(data):
                self.position += count
                return data[start - offset:start - offset + count]
        remaining = self.deadline - time.monotonic()
        if count + self.transferred > MAX_BYTES or self.requests >= MAX_REQUESTS or remaining <= 0:
            raise OSError('Remote HAP metadata budget exceeded')
        self.requests += 1
        headers = {'User-Agent': 'hapstore-collector/1.0', 'Accept': 'application/octet-stream',
                   'Accept-Encoding': 'identity', 'Range': f'bytes={start}-{start + count - 1}'}
        if urlparse(self.url).hostname == 'api.github.com' and self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        if self.etag:
            headers['If-Range'] = self.etag
        with self.opener.open(urllib.request.Request(self.url, headers=headers),
                              timeout=max(1, min(10, remaining))) as response:
            # Reject HTTP 200 before reading any of its potentially huge body.
            expected = f'bytes {start}-{start + count - 1}/{self.size}'
            if (response.status != 206 or response.headers.get('Content-Range') != expected
                    or response.headers.get('Content-Encoding', 'identity') != 'identity'):
                raise OSError('GitHub did not honor the requested byte range')
            if response.headers.get('Content-Length') not in (None, str(count)):
                raise OSError('GitHub range length changed')
            etag = response.headers.get('ETag', '')
            if self.etag and etag != self.etag:
                raise OSError('GitHub asset changed while reading metadata')
            data = response.read(count + 1)
            self.transferred += len(data)
            if len(data) != count:
                raise OSError('GitHub byte range is incomplete')
            final = urlparse(response.url)
            if final.scheme != 'https' or final.hostname not in OFFICIAL_HOSTS:
                raise OSError('Unexpected GitHub asset host')
            self.url, self.etag = response.url, etag
        self.position += count
        self.blocks.append((start, data))
        return data


def inspect(asset, token=''):
    from . import collector
    with RemoteHap(asset.get('_github_api_url', ''), int(asset.get('size') or 0), token) as remote:
        metadata = collector.parse_hap_metadata(remote)
        if (not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+', metadata['bundle_name'])
                or metadata['version_code'] <= 0):
            raise OSError('Large HAP manifest did not identify an application')
        icon = collector.extract_hap_icon(remote)
        if icon:
            metadata['_icon'] = icon
        metadata['_icon_checked'] = not remote.read_failed
        metadata['_icon_status_revision'] = 1
        return metadata
