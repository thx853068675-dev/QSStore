import json
import unittest
from unittest.mock import patch
from server.hapstore import collector, db


class GiteeCollectionTest(unittest.TestCase):
    def test_identity_keeps_platform_and_cannot_collide_with_github(self):
        for value in ['https://gitee.com/Geriay/yuyuebrowser/', 'gitee.com/Geriay/yuyuebrowser.git']:
            self.assertEqual(collector.normalize_repo(value), 'gitee.com/Geriay/yuyuebrowser')
        self.assertEqual(collector.normalize_repo('https://github.com/Geriay/yuyuebrowser'), 'Geriay/yuyuebrowser')
        self.assertIsNone(collector.normalize_repo('https://gitee.com.evil.test/Geriay/yuyuebrowser'))
        self.assertIsNone(collector.normalize_repo('https://gitee.com/o/r?url=http://localhost'))

    def test_gitee_release_installer_attachment_without_digest_is_discovered_but_source_zip_is_excluded(self):
        raw = [{'id': 1, 'tag_name': '1.0.0.Beta', 'prerelease': False, 'created_at': '2026-08-19',
            'assets': [{'name': '屿阅.app', 'browser_download_url': 'https://gitee.com/Geriay/yuyuebrowser/releases/download/1.0.0.Beta/yuyue.app'},
                       {'name': 'source.zip', 'browser_download_url': 'https://gitee.com/Geriay/yuyuebrowser/archive/v1.zip'},
                       {'name': 'bad.hap', 'browser_download_url': 'http://localhost/steal.hap'}]}]
        with patch.object(collector, '_http_get', return_value=json.dumps(raw).encode()) as get:
            rows = collector.fetch_releases('gitee.com/Geriay/yuyuebrowser', token='github-secret')
        self.assertEqual(get.call_args.args[0], 'https://gitee.com/api/v5/repos/Geriay/yuyuebrowser/releases?per_page=100')
        self.assertNotIn('token', get.call_args.kwargs)
        self.assertEqual(len(rows[0]['assets']), 1)
        self.assertEqual(rows[0]['assets'][0]['_github_api_url'], '')
        self.assertIsNone(rows[0]['github_downloads'])
        self.assertFalse(rows[0]['prerelease'], 'use upstream flag, not Beta in title')

    def test_gitee_metadata_and_download_routes_never_use_github_mirrors(self):
        raw = {'name': '屿阅', 'stargazers_count': 4, 'license': 'MIT'}
        with patch.object(collector, '_http_get', return_value=json.dumps(raw).encode()) as get:
            meta = collector.fetch_app_metadata('gitee.com/Geriay/yuyuebrowser', token='github-secret')
        self.assertEqual(meta['display_name'], '屿阅')
        self.assertEqual(meta['stars'], 4)
        self.assertNotIn('token', get.call_args.kwargs)
        url = 'https://gitee.com/Geriay/yuyuebrowser/releases/download/v1/app.hap'
        self.assertEqual(db.mirror_urls(url), [url])

    def test_gitee_attachment_redirects_are_official_https_only(self):
        handler = collector._GiteeRedirects()
        import urllib.request
        req = urllib.request.Request('https://gitee.com/o/r/releases/download/v1/app.hap')
        req.add_header('Authorization', 'must-be-stripped')
        allowed = handler.redirect_request(req, None, 302, 'Found', {}, 'https://foruda.gitee.com/attach/app.hap')
        self.assertFalse(allowed.has_header('Authorization'))
        for url in ['http://foruda.gitee.com/file', 'https://127.0.0.1/private', 'https://foruda.gitee.com.evil.test/file']:
            with self.assertRaises(OSError): handler.redirect_request(req, None, 302, 'Found', {}, url)

    def test_gitee_api_bypasses_the_global_github_proxy(self):
        with patch.object(collector.urllib.request, 'build_opener') as build:
            response = build.return_value.open.return_value.__enter__.return_value
            response.read.return_value = b'{}'; response.headers = {}
            self.assertEqual(collector._http_get('https://gitee.com/api/v5/repos/o/r'), b'{}')
            self.assertTrue(any(getattr(handler, 'proxies', None) == {} for handler in build.call_args.args))
