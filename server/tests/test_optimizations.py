"""Local regressions for bounded collection, conditional reads and constant-query catalogs."""
import hashlib
import io
import json
import os
import tempfile
import threading
import time
import unittest
import urllib.error
from unittest.mock import patch
from server.hapstore import app, artifact_cache, collector, db, package_archive
from server.tests.test_package_archive import hap, pack


class OptimizationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old = db.DB_PATH
        db.DB_PATH = self.temp.name + '/store.db'
        db._local = threading.local()
        db._initialized = False
        db.init_db()
        collector._github_cooldown.clear()

    def tearDown(self):
        db.connect().close()
        db.DB_PATH = self.old
        db._local = threading.local()
        db._initialized = False
        collector._github_cooldown.clear()
        self.temp.cleanup()

    def test_catalog_30_apps_has_constant_queries_and_matches_detail(self):
        for n in range(30):
            id = db.upsert_app(f'owner/app{n}', status='published', display_name=f'App{n}')
            db.set_publisher(id, 'u', '昵称')
            db.replace_releases(id, [dict(tag='v1', name='One', published_at='2026-10-01',
                assets=[dict(name='main.hap', bundle_name=f'com.app{n}', version_code=1,
                    size=100, download_url='https://github.com/o/r/main.hap'),
                    dict(name='helper.hap', bundle_name=f'com.helper{n}', version_code=2,
                    size=50, download_url='https://github.com/o/r/helper.hap')])])
        statements = []
        db.connect().set_trace_callback(statements.append)
        result = db.list_apps(page_size=30)
        db.connect().set_trace_callback(None)
        reads = [sql for sql in statements if sql.lstrip().upper().startswith(('SELECT', 'WITH'))]
        self.assertEqual(len(reads), 9)
        self.assertEqual(len(result['items']), 30)
        for row in result['items']:
            self.assertEqual(row, db.get_app(row['id']))

    def test_profile_polls_do_not_write_and_changed_profile_propagates(self):
        id = db.upsert_app('owner/app', status='published')
        db.set_publisher(id, 'u', '旧昵称')
        db.put_review(id, 'u', '旧昵称', 5, '评论')
        db.sync_account_profile('u', '新昵称', 'https://avatar.example/u.png')
        writes_before = db.connect().total_changes
        statements = []
        db.connect().set_trace_callback(statements.append)
        for _ in range(20):
            db.sync_account_profile('u', '新昵称', 'https://avatar.example/u.png')
        db.connect().set_trace_callback(None)
        self.assertEqual(db.connect().total_changes, writes_before)
        self.assertEqual(statements, [])
        self.assertEqual(db.list_reviews(id)['items'][0]['display_name'], '新昵称')
        db.sync_account_profile('u', 'u', '')
        self.assertEqual(db.list_reviews(id)['items'][0]['display_name'], '新昵称')

    def test_discover_ranks_featured_globally_before_page_slicing(self):
        regular = []
        for n in range(31):
            id = db.upsert_app(f'owner/regular{n}', status='published', stars=100 if n == 0 else 0,
                               display_name=f'App{n}')
            db.connect().execute('UPDATE app SET updated_at=? WHERE id=?', (1000 + n, id))
            regular.append(id)
        featured = []
        for n, stars in enumerate([101, 2000, 10000]):
            id = db.upsert_app(f'owner/featured{n}', status='published', stars=stars,
                               display_name=f'Featured{n}')
            db.connect().execute('UPDATE app SET updated_at=1 WHERE id=?', (id,))
            featured.append(id)
        hidden = db.upsert_app('owner/hidden', status='removed', stars=99999)
        first = db.list_apps(sort='discover', page=1, page_size=30)
        second = db.list_apps(sort='discover', page=2, page_size=30)
        ids = [row['id'] for row in first['items'] + second['items']]
        self.assertEqual(ids, list(reversed(featured)) + list(reversed(regular)))
        self.assertNotIn(hidden, ids)
        self.assertEqual(first['total'], 34)
        self.assertEqual(len(ids), len(set(ids)))
        # Search uses the same global order, while explicit updated order stays intact.
        self.assertEqual([row['id'] for row in db.list_apps(sort='discover', q='Featured')['items']],
                         list(reversed(featured)))
        self.assertEqual(db.list_apps(sort='updated')['items'][0]['id'], regular[-1])

    def test_selected_zip_packages_share_one_verified_download(self):
        data = pack([('a.hap', hap()), ('b.hap', hap(bundle='com.other.app'))])
        asset = dict(name='apps.zip', size=len(data), sha256=hashlib.sha256(data).hexdigest(),
                     download_url='https://github.com/o/r/releases/download/v1/apps.zip')
        def downloaded(*args, **kwargs):
            path = self.temp.name + '/archive.zip'
            with open(path, 'wb') as file:
                file.write(data)
            return path
        with patch.object(collector, '_download_to_temp', side_effect=downloaded) as download:
            assets = package_archive.scan_asset(asset)
            first = package_archive.scan_asset(assets[0])
            second = package_archive.scan_asset(assets[1])
        self.assertEqual(download.call_count, 1)
        self.assertEqual(first[0]['bundle_name'], 'com.example.app')
        self.assertEqual(second[0]['bundle_name'], 'com.other.app')

    def test_corrupt_metadata_cache_is_a_miss_and_digest_is_required(self):
        digest = 'a' * 64
        artifact_cache.put('', 'hap', [dict(bundle_name='com.example', version_code=1)])
        self.assertEqual(db.connect().execute('SELECT count(*) FROM artifact_inspection').fetchone()[0], 0)
        with db.connect():
            db.connect().execute('INSERT INTO artifact_inspection VALUES (?,?,?)',
                (artifact_cache.key(digest, 'hap'), '[42]', 0))
        self.assertIsNone(artifact_cache.get(digest, 'hap'))

    def test_icon_retry_state_survives_disk_cache_without_losing_verified_metadata(self):
        row = dict(bundle_name='com.example.large', version_code=42,
                   _icon_checked=False, _icon_status_revision=1, _icon_retry_at=1900,
                   _icon_attempts=2)
        artifact_cache.put('b' * 64, 'hap-range', [row])
        self.assertEqual(artifact_cache.get('b' * 64, 'hap-range'), [row])

    def test_refresh_deduplicates_and_respects_failure_cooldown(self):
        id = db.upsert_app('owner/app', status='published', last_synced=0)
        self.assertTrue(db.enqueue_refresh(id)['queued'])
        self.assertFalse(db.enqueue_refresh(id)['queued'])
        task = db.claim_refresh()
        self.assertEqual(task['app_id'], id)
        db.finish_refresh(id, 'quota', retry_after=180)
        self.assertFalse(db.enqueue_refresh(id)['queued'])
        self.assertIsNone(db.claim_refresh())
        row = db.connect().execute('SELECT * FROM refresh_task WHERE app_id=?', (id,)).fetchone()
        self.assertGreaterEqual(row['next_attempt'], int(time.time()) + 179)

    def test_public_etag_is_stable_and_private_response_has_no_public_cache(self):
        handler = object.__new__(app.Handler)
        sent = []
        handler.headers = {}
        handler._send = lambda *args: sent.append(args)
        handler._json({'items': [1]}, public=True)
        etag = sent[-1][3]['ETag']
        handler.headers = {'If-None-Match': etag}
        handler._json({'items': [1]}, public=True)
        self.assertEqual(sent[-1][0:2], (304, b''))
        handler._json({'private_key': 'fixture'})
        self.assertEqual(len(sent[-1]), 3)
        self.assertEqual(sent[-1][0], 200)

    def test_github_304_reuses_payload_without_storing_token(self):
        class Response:
            headers = {'ETag': '"v1"'}
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, n): return b'{"name":"test"}'
        token = 'fixture-secret-token'
        with patch.object(collector.urllib.request, 'urlopen', return_value=Response()):
            first = collector._http_get('https://api.github.com/repos/o/r', token=token)
        error = urllib.error.HTTPError('https://api.github.com/repos/o/r', 304, '', {}, None)
        with patch.object(collector.urllib.request, 'urlopen', side_effect=error) as transport:
            second = collector._http_get('https://api.github.com/repos/o/r', token=token)
            self.assertEqual(transport.call_args.args[0].get_header('If-none-match'), '"v1"')
        self.assertEqual(first, second)
        row = db.connect().execute('SELECT * FROM github_http_cache').fetchone()
        self.assertNotIn(token, str(dict(row)))

    def test_github_quota_blocks_all_repositories_sharing_credential(self):
        headers = {'X-RateLimit-Remaining': '0', 'Retry-After': '120'}
        error = urllib.error.HTTPError('https://api.github.com/repos/o/r', 403, '', headers, None)
        with patch.object(collector.urllib.request, 'urlopen', side_effect=error) as transport:
            with self.assertRaises(collector.CollectError) as first:
                collector._http_get('https://api.github.com/repos/o/r', token='same')
            with self.assertRaises(collector.CollectError):
                collector._http_get('https://api.github.com/repos/other/repo', token='same')
            self.assertEqual(transport.call_count, 1)
        self.assertEqual(first.exception.retry_after, 120)
