import copy
import io
import json
import re
import unittest
import urllib.request
import urllib.error
import zipfile
from unittest.mock import patch
from PIL import Image
from server.hapstore import collector, remote_hap


class Response:
    def __init__(self, data, start, total, status=206, etag='"asset-1"'):
        self.data, self.reads, self.status = data, 0, status
        self.url = 'https://release-assets.githubusercontent.com/example/hap'
        self.headers = {'Content-Range': f'bytes {start}-{start + len(data) - 1}/{total}',
                        'Content-Length': str(len(data)), 'ETag': etag}

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def read(self, count):
        self.reads += 1
        return self.data[:count]


class OfficialAsset:
    def __init__(self, body, prefix=0):
        self.body, self.prefix, self.requests = body, prefix, []

    def open(self, request, timeout):
        self.requests.append(request)
        start, end = map(int, re.fullmatch(r'bytes=(\d+)-(\d+)', request.get_header('Range')).groups())
        total = self.prefix + len(self.body)
        data = bytes(max(0, min(end + 1, self.prefix) - start))
        data += self.body[max(0, start - self.prefix):end + 1 - self.prefix]
        return Response(data, start, total)


class RemoteHapTest(unittest.TestCase):
    url = 'https://api.github.com/repos/owner/repo/releases/assets/123'

    def test_large_hap_metadata_uses_small_official_ranges_and_then_cache(self):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('pack.info', json.dumps({'summary': {'app': {
                'bundleName': 'com.example.ohcode', 'version': {'code': 1000000, 'name': '1.0.0'}}}}))
            z.writestr('module.json', json.dumps({'app': {
                'bundleName': 'com.example.ohcode', 'versionCode': 1000000, 'label': 'OHcode'}}))
        origin = OfficialAsset(archive.getvalue(), prefix=collector.MAX_HAP_SCAN + 1)
        asset = {'name': 'OHcode.hap', 'size': origin.prefix + len(origin.body),
                 'sha256': 'a' * 64, '_github_api_url': self.url,
                 'download_url': 'https://github.com/owner/repo/releases/download/v1/OHcode.hap'}
        with patch.object(remote_hap.urllib.request, 'build_opener', return_value=origin), \
             patch('server.hapstore.artifact_cache.get', return_value=None), \
             patch('server.hapstore.artifact_cache.put') as cache, \
             patch.object(collector, '_download_to_temp', side_effect=AssertionError('full download')):
            collector.enrich_assets_with_hap_metadata([{'assets': [asset]}], token='private-token')
        self.assertEqual(asset['bundle_name'], 'com.example.ohcode')
        self.assertEqual(asset['version_code'], 1000000)
        self.assertEqual(cache.call_args.args[1], 'hap-range')
        self.assertLess(sum(int(r.get_header('Range').split('-')[1]) -
            int(r.get_header('Range').split('=')[1].split('-')[0]) + 1 for r in origin.requests), 100000)
        self.assertEqual(origin.requests[0].get_header('Authorization'), 'Bearer private-token')
        self.assertTrue(all(r.get_header('Authorization') is None for r in origin.requests[1:]))
        with patch('server.hapstore.artifact_cache.get', side_effect=[None, [asset]]), \
             patch.object(remote_hap, 'inspect', side_effect=AssertionError('cached range fetched again')):
            collector.enrich_assets_with_hap_metadata([{'assets': [dict(asset)]}])

    def icon_asset(self):
        png = io.BytesIO()
        Image.new('RGB', (64, 64), 'blue').save(png, format='PNG')
        body = io.BytesIO()
        with zipfile.ZipFile(body, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('pack.info', json.dumps({'summary': {'app': {
                'bundleName': 'com.example.large', 'version': {'code': 42, 'name': '1.2.3'}}}}))
            z.writestr('module.json', json.dumps({'app': {
                'bundleName': 'com.example.large', 'versionCode': 42, 'icon': '$media:app_icon'}}))
            z.writestr('resources/base/media/app_icon.png', png.getvalue())
            header = z.getinfo('resources/base/media/app_icon.png').header_offset
        origin = OfficialAsset(body.getvalue(), prefix=collector.MAX_HAP_SCAN + 1)
        asset = {'name': 'large.hap', 'size': origin.prefix + len(origin.body), 'sha256': 'b' * 64,
                 '_github_api_url': self.url,
                 'download_url': 'https://github.com/owner/repo/releases/download/v1/large.hap'}
        return origin, asset, origin.prefix + header

    def test_icon_range_failure_retries_with_backoff_and_recovers_without_full_download(self):
        origin, asset, icon_start = self.icon_asset()
        original_open = origin.open
        fail = True
        now = 1000
        cache = {}
        def open_range(request, timeout):
            start = int(re.fullmatch(r'bytes=(\d+)-(\d+)', request.get_header('Range')).group(1))
            if fail and start == icon_start:
                origin.requests.append(request)
                raise urllib.error.URLError('temporary icon timeout')
            return original_open(request, timeout)
        origin.open = open_range
        def put(sha, kind, rows): cache[(sha, kind)] = copy.deepcopy(rows)
        def get(sha, kind): return copy.deepcopy(cache.get((sha, kind)))
        def enrich():
            row = dict(asset)
            collector.enrich_assets_with_hap_metadata([{'assets': [row]}])
            return row
        with patch.object(remote_hap.urllib.request, 'build_opener', return_value=origin), \
             patch('server.hapstore.artifact_cache.get', side_effect=get), \
             patch('server.hapstore.artifact_cache.put', side_effect=put), \
             patch.object(collector.time, 'time', side_effect=lambda: now), \
             patch.object(collector, '_download_to_temp', side_effect=AssertionError('full download')):
            first = enrich()
            self.assertEqual(first['bundle_name'], 'com.example.large')
            self.assertFalse(first['_icon_checked'])
            self.assertNotIn('_icon', first)
            self.assertEqual(first['_icon_retry_at'], 1300)
            requests = len(origin.requests)
            self.assertFalse(enrich()['_icon_checked'])
            self.assertEqual(len(origin.requests), requests, 'backoff avoids repeated range requests')
            now = 1300
            self.assertFalse(enrich()['_icon_checked'])
            self.assertEqual(cache[(asset['sha256'], 'hap-range')][0]['_icon_retry_at'], 1900)
            fail = False
            now = 1900
            healthy = enrich()
            self.assertTrue(healthy['_icon_checked'])
            self.assertEqual(healthy['_icon'][0], 'image/png')
            requests = len(origin.requests)
            self.assertEqual(enrich()['_icon'], healthy['_icon'])
            self.assertEqual(len(origin.requests), requests, 'successful icon remains cached')

    def test_old_negative_range_cache_is_repaired_once(self):
        origin, asset, _ = self.icon_asset()
        old = {'bundle_name': 'com.example.large', 'version_code': 42, '_icon_checked': True}
        with patch.object(remote_hap.urllib.request, 'build_opener', return_value=origin), \
             patch('server.hapstore.artifact_cache.get', side_effect=[None, [old]]), \
             patch('server.hapstore.artifact_cache.put') as cache:
            collector.enrich_assets_with_hap_metadata([{'assets': [asset]}])
        self.assertTrue(asset['_icon_checked'])
        self.assertIn('_icon', asset)
        self.assertEqual(cache.call_args.args[2][0]['_icon_status_revision'], 1)

    def test_failed_retry_retains_manifest_and_extends_backoff(self):
        _, asset, _ = self.icon_asset()
        old = {'bundle_name': 'com.example.large', 'version_code': 42,
               '_icon_checked': False, '_icon_status_revision': 1, '_icon_retry_at': 1000,
               '_icon_attempts': 1}
        with patch('server.hapstore.artifact_cache.get', side_effect=[None, [old]]), \
             patch('server.hapstore.artifact_cache.put') as cache, \
             patch.object(collector.time, 'time', return_value=1300), \
             patch.object(remote_hap, 'inspect', side_effect=OSError('temporary manifest timeout')):
            collector.enrich_assets_with_hap_metadata([{'assets': [asset]}])
        self.assertEqual(asset['bundle_name'], old['bundle_name'])
        self.assertEqual(cache.call_args.args[2][0]['_icon_retry_at'], 1900)

    def test_ignored_range_rejects_before_reading_any_body(self):
        response = Response(b'huge-body', 0, 100, status=200)
        with patch.object(remote_hap.urllib.request, 'build_opener') as make:
            make.return_value.open.return_value = response
            with remote_hap.RemoteHap(self.url, 100) as reader:
                with self.assertRaises(OSError): reader.read(9)
        self.assertEqual(response.reads, 0)

    def test_wrong_ranges_and_changed_assets_are_rejected(self):
        for response in [Response(b'12', 1, 100), Response(b'12', 0, 101)]:
            with patch.object(remote_hap.urllib.request, 'build_opener') as make:
                make.return_value.open.return_value = response
                with remote_hap.RemoteHap(self.url, 100) as reader:
                    with self.assertRaises(OSError): reader.read(2)
                self.assertEqual(response.reads, 0)
        with patch.object(remote_hap.urllib.request, 'build_opener') as make:
            make.return_value.open.side_effect = [Response(b'12', 0, 100),
                                                Response(b'34', 2, 100, etag='"asset-2"')]
            with remote_hap.RemoteHap(self.url, 100) as reader:
                self.assertEqual(reader.read(2), b'12')
                with self.assertRaises(OSError): reader.read(2)

    def test_range_budget_and_cached_seeks(self):
        origin = OfficialAsset(b'0123456789')
        with patch.object(remote_hap.urllib.request, 'build_opener', return_value=origin), \
             patch.object(remote_hap, 'MAX_BYTES', 4):
            with remote_hap.RemoteHap(self.url, 10) as reader:
                self.assertEqual(reader.read(4), b'0123')
                reader.seek(1)
                self.assertEqual(reader.read(2), b'12')
                reader.seek(4)
                with self.assertRaises(OSError): reader.read(1)
        self.assertEqual(len(origin.requests), 1)

    def test_only_official_urls_and_no_token_forwarding(self):
        with self.assertRaises(OSError): remote_hap.RemoteHap('https://mirror.example/hap', 100)
        handler = remote_hap.OfficialRedirects()
        request = urllib.request.Request(self.url, headers={'Authorization': 'Bearer secret', 'Range': 'bytes=0-1'})
        redirected = handler.redirect_request(request, None, 302, '', {},
            'https://release-assets.githubusercontent.com/example')
        self.assertIsNone(redirected.get_header('Authorization'))
        with self.assertRaises(OSError):
            handler.redirect_request(request, None, 302, '', {}, 'https://unknown.example/package')


if __name__ == '__main__':
    unittest.main()
