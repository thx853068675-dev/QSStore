"""GitHub release totals stay separate from store events and expanded packages."""
import os
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from server.hapstore import collector, db, transfer


class GithubDownloadsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old_db = db.DB_PATH
        db.DB_PATH = os.path.join(self.temp.name, 'store.db')
        db._local = threading.local()
        db._initialized = False
        db.init_db()

    def tearDown(self):
        db.connect().close()
        db.DB_PATH = self.old_db
        db._local = threading.local()
        db._initialized = False
        self.temp.cleanup()

    @staticmethod
    def release(tag, count=None, preview=False):
        return dict(tag=tag, prerelease=preview, github_downloads=count,
                    assets=[dict(name='app.hap', bundle_name='com.example.app', size=10)])

    def test_paginated_counts_include_all_attachments_and_previews_but_not_drafts(self):
        def raw(tag, assets, **fields):
            return dict(tag_name=tag, assets=[dict(name=n, download_count=c)
                                             for n, c in assets], **fields)
        page = [raw(str(i), [('app.hap', 1)]) for i in range(100)]
        page[0] = raw('v1', [('apps.zip', 20), ('desktop.exe', 40), ('checksums.txt', 2)])
        last = [raw('preview', [('app.hap', 3)], prerelease=True),
                raw('draft', [('app.hap', 900)], draft=True)]
        with patch.object(collector, '_json', side_effect=[page, last]) as get:
            releases = collector.fetch_releases('o/r')
        self.assertEqual(get.call_count, 2, 'totals must use the existing release responses')
        self.assertEqual(sum(r['github_downloads'] for r in releases), 164)
        first = next(r for r in releases if r['tag'] == 'v1')
        self.assertEqual([a['name'] for a in first['assets']], ['apps.zip'])
        # Expanding one ZIP into two selected HAPs cannot double its GitHub count.
        first['assets'] = [dict(name='a.hap', size=1), dict(name='b.hap', size=1)]
        app_id = db.upsert_app('o/r')
        db.replace_releases(app_id, releases)
        self.assertEqual(db.get_app(app_id)['github_downloads'], 164)

    def test_list_detail_updates_deletions_and_store_events_use_the_same_total(self):
        app_id = db.upsert_app('o/r')
        db.replace_releases(app_id, [self.release('v1', 12), self.release('v2', 8, True)])
        db.record_download(app_id, 1, 'device')
        self.assertEqual(db.download_counts(app_id), 1)
        self.assertEqual(db.get_app(app_id)['github_downloads'], 20)
        self.assertEqual(db.list_apps()['items'][0]['github_downloads'], 20)
        self.assertEqual(db.list_apps()['items'][0]['releases_count'], 1)
        db.replace_releases(app_id, [self.release('v1', 30)])
        self.assertEqual(db.get_app(app_id)['github_downloads'], 30)
        # GitHub recreating an asset resets its counter. Do not take MAX or add deltas.
        db.replace_releases(app_id, [self.release('v1', 0)])
        self.assertEqual(db.list_apps()['items'][0]['github_downloads'], 0)

    def test_incomplete_or_legacy_counts_are_unknown_not_a_fabricated_zero(self):
        app_id = db.upsert_app('o/r')
        self.assertIsNone(db.get_app(app_id)['github_downloads'])
        db.replace_releases(app_id, [self.release('v1', 2), self.release('legacy')])
        self.assertIsNone(db.list_apps()['items'][0]['github_downloads'])
        rows = [dict(tag_name='bad', assets=[dict(name='a.hap', download_count=-3)]),
                dict(tag_name='legacy', assets=[dict(name='a.hap')]),
                dict(tag_name='empty', assets=[])]
        with patch.object(collector, '_json', return_value=rows):
            releases = collector.fetch_releases('o/r')
        self.assertEqual([r['github_downloads'] for r in releases], [None, None, 0])

    def test_cached_snapshot_and_transfer_keep_the_complete_history(self):
        app_id = db.upsert_app('o/r', synced_at=int(time.time()))
        releases = [self.release(str(i), i + 1) for i in range(35)]
        db.replace_releases(app_id, releases)
        snapshot = db.cached_repository_snapshot('o/r', 60)
        self.assertEqual(len(snapshot['releases']), 35)
        self.assertEqual(sum(r['github_downloads'] for r in snapshot['releases']), 630)
        exported = transfer.export_all()
        db.replace_releases(app_id, [self.release('changed', 1)])
        transfer.import_all(exported)
        self.assertEqual(db.get_app(app_id)['github_downloads'], 630)

    def test_migration_preserves_old_releases_and_can_run_again(self):
        db.connect().close()
        db.DB_PATH = os.path.join(self.temp.name, 'legacy.db')
        db._local = threading.local()
        old_schema = '\n'.join(line for line in db.SCHEMA.splitlines()
                               if 'github_downloads INTEGER' not in line)
        db.connect().executescript(old_schema)
        db.connect().execute("""INSERT INTO app(repo_full_name,owner,name,created_at,updated_at)
                                VALUES ('o/r','o','r',1,1)""")
        db.connect().execute("INSERT INTO release(app_id,tag) VALUES (1,'old')")
        db.connect().commit()
        db._initialized = False
        db.init_db()
        self.assertIsNone(db.get_app(1)['github_downloads'])
        self.assertEqual(db.list_releases(1)['items'][0]['tag'], 'old')
        db._initialized = False
        db.init_db()
        self.assertEqual(db.list_releases(1)['total'], 1)


if __name__ == '__main__':
    unittest.main()
