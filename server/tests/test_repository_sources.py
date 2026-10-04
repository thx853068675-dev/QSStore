"""Verified source linking, merged catalog identity and bounded background sync."""
import copy
import hashlib
import json
import os
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from server.hapstore import app, collector, db, submissions
from server.tests.test_package_archive import hap


class RepositorySourceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old = db.DB_PATH
        db.DB_PATH = self.temp.name + '/store.db'
        db._local = threading.local(); db._initialized = False; db.init_db()
        app._rl.clear(); submissions._cache.clear(); submissions._inflight.clear()
        self.id = db.upsert_app('dev/main', display_name='原应用', category='工具', stars=90)
        db.set_publisher(self.id, 'owner', '上架者')
        db.replace_releases(self.id, [self.release('v1', '2026-10-01', 1, downloads=10)])
        self.identity = ('owner', '上架者')

    def tearDown(self):
        db.connect().close(); db.DB_PATH = self.old
        db._local = threading.local(); db._initialized = False
        self.temp.cleanup()

    def release(self, tag, date, code, bundle='com.example.app', downloads=20, preview=False):
        return dict(tag=tag, name=tag, published_at=date, prerelease=preview,
            github_downloads=downloads, assets=[dict(name='app.hap', size=100,
                download_url='https://github.com/mirror/releases/releases/download/'+tag+'/app.hap',
                sha256='a'*64, bundle_name=bundle, version_code=code, version_name=str(code))])

    def draft(self, releases=None, repo='mirror/releases', token='draft', account='owner', fetched=None):
        releases = copy.deepcopy(releases or [self.release('v2', '2026-10-02', 2)])
        snapshot = dict(metadata=dict(display_name='镜像不应覆盖名称', stars=30, category='游戏'),
            releases=releases, fetched_at=fetched or int(time.time()))
        choices = [dict(tag=releases[0]['tag'], **a) for a in releases[0]['assets']]
        db.create_submit_draft(token, repo, account, choices, '工具', dict(snapshot=snapshot))
        return token

    def link(self, token='draft', id=None):
        return app.h_configure_my_app(str(id or self.id), dict(category='工具', source_draft_token=token), self.identity)['app']

    def test_link_keeps_primary_presentation_and_sums_counts_before_pagination(self):
        self.draft(); linked=self.link()
        self.assertEqual(linked['display_name'], '原应用')
        self.assertEqual(linked['publisher_name'], '上架者')
        self.assertEqual(linked['repo'], 'dev/main')
        self.assertEqual(linked['secondary_repo'], 'mirror/releases')
        self.assertEqual((linked['stars'], linked['github_downloads']), (120,30))
        self.assertEqual(linked['latest_asset']['version_code'], 2)
        other=db.upsert_app('other/repo', stars=115)
        self.assertEqual(db.list_apps(sort='discover', page_size=1)['items'][0]['id'], self.id)
        self.assertEqual(db.list_apps(sort='stars', page_size=1)['items'][0]['id'], self.id)
        self.assertEqual(db.list_published_by_account('owner')[0], linked)
        self.assertEqual(db.list_apps()['total'], 2, 'raw source does not become another listing')

    def test_same_tags_survive_pagination_and_preview_channels_remain_separate(self):
        self.draft([self.release('v1','2026-10-02',2),self.release('beta','2026-10-03',3,preview=True)])
        self.link()
        first=db.list_releases(self.id,page_size=1)
        second=db.list_releases(self.id,page=2,page_size=1)
        self.assertEqual(first['total'],2)
        self.assertEqual((first['items'][0]['tag'],second['items'][0]['tag']),('v1','v1'))
        self.assertEqual([first['items'][0]['source_kind'],second['items'][0]['source_kind']],['secondary','primary'])
        preview=db.list_releases(self.id,prerelease_only=True)['items']
        self.assertEqual([r['tag'] for r in preview],['beta'])
        self.assertEqual(preview[0]['assets'][0]['version_code'],3)

    def test_wrong_package_is_rejected_atomically_and_current_association_survives(self):
        self.draft(); self.link()
        self.draft([self.release('v3','2026-10-03',3,bundle='com.other.app')],repo='bad/repo',token='bad')
        with self.assertRaises(app.ApiError) as error:
            app.h_configure_my_app(str(self.id),dict(category='游戏',source_draft_token='bad'),self.identity)
        self.assertEqual(error.exception.code,'SOURCE_BUNDLE_MISMATCH')
        self.assertEqual(db.get_app(self.id)['secondary_repo'],'mirror/releases')
        self.assertEqual(db.get_app(self.id)['category'],'工具')
        self.assertIsNone(db.get_app_by_repo('bad/repo'))

    def test_uninspected_filename_and_old_matching_history_do_not_pass_validation(self):
        unknown=self.release('com.example.app-v9','2026-10-09',0,bundle='')
        self.draft([unknown,self.release('v1','2026-10-01',1)])
        with self.assertRaises(app.ApiError): self.link()
        self.assertEqual(db.get_app(self.id)['secondary_repo'],'')

    def test_ownership_and_draft_account_are_rechecked_on_save(self):
        self.draft()
        with self.assertRaises(app.ApiError) as error:
            app.h_configure_my_app(str(self.id),dict(category='工具',source_draft_token='draft'),('other','Other'))
        self.assertEqual(error.exception.status,403)
        db.connect().execute("UPDATE publisher SET account_id='other' WHERE app_id=?",(self.id,));db.connect().commit()
        with self.assertRaises(app.ApiError): self.link()
        self.assertIsNone(db.get_app_by_repo('mirror/releases'))

    def test_expired_or_running_drafts_cannot_be_linked(self):
        self.draft()
        db.queue_archive_inspection('draft')
        with self.assertRaises(app.ApiError): self.link()
        db.connect().execute("UPDATE submit_draft SET inspection_state='ready',expires_at=0");db.connect().commit()
        with self.assertRaises(app.ApiError): self.link()

    def test_primary_is_not_its_own_source_case_insensitively(self):
        self.draft(repo='DEV/MAIN')
        with self.assertRaises(app.ApiError) as error: self.link()
        self.assertEqual(error.exception.code,'SOURCE_IS_PRIMARY')

    def test_future_wrong_bundle_is_hidden_but_repository_download_total_is_retained(self):
        self.draft();self.link()
        source=db.get_app_by_repo('mirror/releases')['id']
        db.replace_releases(source,[self.release('v4','2026-10-04',4,bundle='com.wrong.app',downloads=99),
            self.release('v3','2026-10-03',3),self.release('v2','2026-10-02',2)])
        linked=db.get_app(self.id)
        self.assertEqual(linked['latest_asset']['version_code'],3)
        self.assertEqual(linked['github_downloads'],149)
        self.assertEqual([r['tag'] for r in db.list_releases(self.id)['items']],['v3','v2','v1'])

    def test_one_updated_package_does_not_hide_other_primary_packages(self):
        release=self.release('v1','2026-10-01',1)
        release['assets'].append(dict(release['assets'][0],name='helper.hap',bundle_name='com.example.helper',size=50))
        db.replace_releases(self.id,[release]);self.draft();self.link()
        self.assertEqual({a['bundle_name']:a['version_code'] for a in db.get_app(self.id)['latest_assets']},
            {'com.example.app':2,'com.example.helper':1})

    def test_unknown_download_count_is_not_shown_as_a_complete_sum(self):
        self.draft([self.release('v2','2026-10-02',2,downloads=None)]);self.link()
        self.assertIsNone(db.get_app(self.id)['github_downloads'])

    def test_unlink_and_unlist_remove_source_versions_and_stop_idle_collection(self):
        self.draft();self.link()
        app.h_configure_my_app(str(self.id),dict(category='工具',remove_secondary=True),self.identity)
        self.assertEqual(db.get_app(self.id)['stars'],90)
        self.assertEqual(db.list_releases(self.id)['total'],1)
        self.link()
        db.hide_published_app(self.id,'owner')
        self.assertEqual(db.apps_needing_sync(max_age_seconds=0),[])

    def test_existing_published_source_owner_and_selection_are_not_mutated(self):
        source=db.upsert_app('mirror/releases',display_name='别人的应用',category='游戏',stars=30)
        db.set_publisher(source,'another','另一人')
        db.replace_releases(source,[self.release('v2','2026-10-02',2)])
        self.draft();self.link()
        self.assertEqual(db.get_app(source)['display_name'],'别人的应用')
        self.assertEqual(db.publisher_account_id(source),'another')
        self.assertEqual(db.get_app(source)['category'],'游戏')

    def test_shared_source_is_queued_once_and_manual_refresh_waits_for_both(self):
        self.draft(fetched=1);self.link()
        other=db.upsert_app('dev/another',stars=5);db.set_publisher(other,'owner','上架者')
        db.replace_releases(other,[self.release('v1','2026-10-01',1)])
        self.link(id=other)
        ids=db.catalog_repository_ids(self.id)
        self.assertEqual(len(ids),2)
        self.assertEqual(len({r['id'] for r in db.apps_needing_sync(max_age_seconds=0)}),3)
        # Sources share one durable refresh task instead of a task per listing.
        self.assertEqual(db.connect().execute('SELECT COUNT(*) FROM refresh_task WHERE app_id=?',(ids[1],)).fetchone()[0],1)
        self.assertEqual(app.h_refresh_app(str(self.id),'ip')['status'],'pending')
        db.finish_refresh(self.id)
        self.assertEqual(app.h_refresh_status(str(self.id))['status'],'pending')
        db.finish_refresh(ids[1])
        self.assertEqual(app.h_refresh_status(str(self.id))['status'],'done')

    def test_prepare_parses_real_hap_in_background_before_linking(self):
        data=hap(code=2);digest=hashlib.sha256(data).hexdigest()
        release=self.release('v2','2026-10-02',0,bundle='')
        release['assets'][0].update(sha256=digest,size=len(data))
        snapshot=dict(metadata=dict(display_name='Mirror',category='工具',description='',stars=30),
            releases=[release],fetched_at=int(time.time()))
        def transfer(*args,**kwargs):
            fd,path=tempfile.mkstemp(dir=self.temp.name)
            with os.fdopen(fd,'wb') as f:f.write(data)
            return path
        with patch.object(submissions,'prepared_snapshot',return_value=snapshot), \
             patch.object(collector,'_download_to_temp',side_effect=transfer) as download:
            draft=app.h_prepare_app_source(str(self.id),dict(repo_url='https://github.com/mirror/releases'),'ip',self.identity)
            self.assertEqual(draft['inspection_status'],'pending');download.assert_not_called()
            with self.assertRaises(app.ApiError):self.link(token=draft['draft_token'])
            self.assertTrue(submissions.process_prepare_one())
            status=app.h_submit_status(dict(draft_token=draft['draft_token']),self.identity)
            self.assertEqual(status['inspection_status'],'ready')
            self.assertEqual(status['choices'][0]['bundle_name'],'com.example.app')
            linked=self.link(token=draft['draft_token'])
            self.assertEqual(linked['latest_asset']['version_code'],2)
            self.assertEqual(download.call_count,1)


if __name__=='__main__':unittest.main()
