"""Repository aliases, concurrent listing and old draft entry-point regressions."""
import json
import base64
from io import BytesIO
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
from PIL import Image
from server.hapstore import app, collector, db, submission_repository as repository
from server.tests import test_background_submit as background


class SubmissionRepositoryTest(unittest.TestCase):
    setUp = background.BackgroundSubmitTest.setUp
    tearDown = background.BackgroundSubmitTest.tearDown

    def identity(self, repo='owner/current', remote_id=42, provider='github'):
        return dict(provider=provider, remote_id=remote_id, canonical_repo=repo)

    def prepare(self, repo='owner/current', account='alice'):
        url = ('https://' if repo.startswith('gitee.com/') else 'https://github.com/') + repo
        return app.h_submit_prepare(dict(repo_url=url), 'ip', (account, account))

    def confirm(self, draft, account='alice'):
        return app.h_submit_confirm(dict(draft_token=draft['draft_token'],
            asset_name='main-v2.hap', category='工具'), (account, account))['app']

    def seed(self, repo, owner, *, status='published', identity=None):
        app_id = db.upsert_app(repo, display_name='Existing app', status=status)
        db.set_publisher(app_id, owner, owner)
        with db.connect() as c:
            repository.bind(c, app_id, identity or self.identity())
        return app_id

    def test_old_and_new_paths_block_foreign_listing_without_touching_original(self):
        app_id = self.seed('owner/old', 'bob')
        before = dict(db.connect().execute('SELECT * FROM app WHERE id=?', (app_id,)).fetchone())
        with patch.object(repository, 'resolve', return_value=self.identity()):
            draft = self.prepare()
            self.assertEqual(draft['existing'], dict(state='other', app_id=app_id))
            with self.assertRaises(app.ApiError) as error:
                self.confirm(draft)
        self.assertEqual(error.exception.code, 'PUBLISHER_MISMATCH')
        self.assertEqual(before, dict(db.connect().execute('SELECT * FROM app WHERE id=?', (app_id,)).fetchone()))
        self.assertEqual(db.connect().execute('SELECT count(*) FROM app').fetchone()[0], 1)

    def test_same_owner_uses_existing_id_and_path_after_rename(self):
        app_id = self.seed('owner/old', 'alice')
        with patch.object(repository, 'resolve', return_value=self.identity()):
            draft = self.prepare()
            self.assertEqual(draft['existing'], dict(state='mine', app_id=app_id))
            saved = self.confirm(draft)
            self.confirm(draft)
        self.assertEqual((saved['id'], saved['repo']), (app_id, 'owner/old'))
        self.assertEqual(db.connect().execute('SELECT count(*) FROM app').fetchone()[0], 1)

    def test_concurrent_aliases_cannot_create_two_apps(self):
        with patch.object(repository, 'resolve', return_value=self.identity()):
            a = self.prepare('owner/old', 'alice')
            b = self.prepare('owner/current', 'bob')
            barrier = threading.Barrier(2)
            def submit(draft, owner):
                try:
                    barrier.wait()
                    return self.confirm(draft, owner)['id']
                except app.ApiError as error:
                    return error.code
                finally:
                    db.connect().close()
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(submit, a, 'alice'), pool.submit(submit, b, 'bob')]
                results = [f.result() for f in futures]
        self.assertEqual(sum(isinstance(r, int) for r in results), 1)
        self.assertIn('PUBLISHER_MISMATCH', results)
        self.assertEqual(db.connect().execute('SELECT count(*) FROM app').fetchone()[0], 1)

    def test_historical_duplicates_keep_ids_and_each_owner_can_manage_own(self):
        a = self.seed('owner/old', 'alice')
        b = self.seed('owner/current', 'bob')
        with patch.object(repository, 'resolve', return_value=self.identity()):
            self.assertEqual(self.confirm(self.prepare(), 'alice')['id'], a)
            self.assertEqual(self.confirm(self.prepare('owner/current', 'bob'), 'bob')['id'], b)
            with self.assertRaises(app.ApiError):
                self.confirm(self.prepare('owner/other-alias', 'charlie'), 'charlie')
        self.assertEqual(db.connect().execute('SELECT count(*) FROM app').fetchone()[0], 2)
        self.assertEqual((db.publisher_account_id(a), db.publisher_account_id(b)), ('alice', 'bob'))

    def test_hidden_alias_can_be_relisted_without_creating_row(self):
        app_id = self.seed('owner/old', 'bob', status='hidden')
        db.put_review(app_id, 'bob', 'Bob', 4, 'Review before unlisting')
        with patch.object(repository, 'resolve', return_value=self.identity()):
            self.assertEqual(self.confirm(self.prepare())['id'], app_id)
        self.assertEqual(db.publisher_account_id(app_id), 'alice')
        self.assertEqual(db.review_summary(app_id)['count'], 1)

    def test_custom_presentation_survives_collection_and_updates_in_place(self):
        images = []
        for color in ('navy', 'green', 'pink', 'orange', 'teal', 'purple'):
            image = BytesIO()
            Image.new('RGB', (100, 150), color).save(image, 'JPEG')
            images.append(base64.b64encode(image.getvalue()).decode())
        with patch.object(repository, 'resolve', return_value=self.identity()):
            draft = self.prepare()
            details = app.h_submit_confirm(dict(draft_token=draft['draft_token'],
                asset_name='main-v2.hap', category='工具', presentation={
                    'display_name': '自定义名称', 'description': '自定义介绍', 'screenshots': images
                }), ('alice', 'Alice'))['app']
        app_id = details['id']
        self.assertEqual(len(details['screenshots']), 6)
        digest = details['screenshots'][0]
        with self.assertRaises(app.ApiError) as over_limit:
            app.h_configure_my_app(str(app_id), dict(category='工具', presentation={
                'screenshots': images + [images[0]]}), ('alice', 'Alice'))
        self.assertEqual(over_limit.exception.code, 'INVALID_SCREENSHOT')
        db.upsert_app(details['repo'], display_name='Collected name', description='Collected', summary='Collected')
        self.assertEqual(db.get_app(app_id)['display_name'], '自定义名称')
        self.assertEqual(db.get_app(app_id)['custom_display_name'], '自定义名称')
        self.assertEqual(db.get_app(app_id)['description'], '自定义介绍')
        with self.assertRaises(app.ApiError) as error:
            app.h_configure_my_app(str(app_id), dict(category='工具', presentation={'screenshots': []}), ('bob', 'Bob'))
        self.assertEqual(error.exception.status, 403)
        with self.assertRaises(app.ApiError) as error:
            app.h_configure_my_app(str(app_id), dict(category='工具', presentation={
                'display_name': '不会保存', 'screenshots': ['0' * 24]
            }), ('alice', 'Alice'))
        self.assertEqual(error.exception.code, 'INVALID_SCREENSHOT')
        self.assertEqual(db.get_app(app_id)['display_name'], '自定义名称')
        updated = app.h_configure_my_app(str(app_id), dict(category='工具', presentation={
            'display_name': '新的商店名称', 'description': '新介绍', 'screenshots': [digest]
        }), ('alice', 'Alice'))['app']
        self.assertEqual(updated['custom_display_name'], '新的商店名称')
        stored = next(item for item in db.list_apps(q='新的商店名称')['items'] if item['id'] == app_id)
        self.assertEqual(stored['custom_display_name'], '新的商店名称')
        self.assertEqual((updated['id'], updated['summary'], updated['screenshots']), (app_id, '新介绍', [digest]))
        updated = app.h_configure_my_app(str(app_id), dict(category='工具', presentation={'screenshots': []}),
                                         ('alice', 'Alice'))['app']
        self.assertEqual(updated['screenshots'], [])

    def test_distinct_forks_with_same_bundle_are_allowed(self):
        self.releases[0]['assets'][0]['bundle_name'] = 'com.example.same'
        with patch.object(repository, 'resolve', side_effect=lambda repo, **kw:
                self.identity(repo, 42 if repo == 'owner/main' else 43)):
            a = self.confirm(self.prepare('owner/main'))
            b = self.confirm(self.prepare('fork/main', 'bob'), 'bob')
        self.assertNotEqual(a['id'], b['id'])

    def test_repository_ids_are_provider_scoped(self):
        with patch.object(repository, 'resolve', side_effect=lambda repo, **kw:
                self.identity(repo, 42, 'gitee' if repo.startswith('gitee.com/') else 'github')):
            a = self.confirm(self.prepare())
            b = self.confirm(self.prepare('gitee.com/owner/current', 'bob'), 'bob')
        self.assertNotEqual(a['id'], b['id'])

    def test_changed_identity_between_prepare_and_confirm_is_rejected(self):
        with patch.object(repository, 'resolve', side_effect=[self.identity(), self.identity(remote_id=43)]):
            draft = self.prepare()
            with self.assertRaises(app.ApiError) as error:
                self.confirm(draft)
        self.assertEqual(error.exception.code, 'REPOSITORY_CHANGED')
        self.assertEqual(db.connect().execute('SELECT count(*) FROM app').fetchone()[0], 0)

    def test_reused_repository_path_cannot_take_over_existing_app(self):
        app_id = self.seed('owner/current', 'alice')
        with patch.object(repository, 'resolve', return_value=self.identity(remote_id=43)):
            with self.assertRaises(app.ApiError) as error:
                self.prepare()
        self.assertEqual(error.exception.code, 'REPOSITORY_CHANGED')
        self.assertEqual(db.publisher_account_id(app_id), 'alice')

    def test_legacy_draft_is_rechecked_and_completed_retry_needs_no_upstream(self):
        with patch.object(repository, 'resolve', return_value=self.identity()):
            draft = self.prepare()
            c = db.connect()
            stored = json.loads(db.get_submit_draft(draft['draft_token'], 'alice')['prepared_json'])
            stored['snapshot'].pop('repository_identity')
            c.execute('UPDATE submit_draft SET prepared_json=? WHERE token=?', (json.dumps(stored), draft['draft_token']))
            c.commit()
            saved = self.confirm(draft)
        with patch.object(repository, 'resolve', side_effect=collector.CollectError('offline')) as resolve:
            self.assertEqual(self.confirm(draft)['id'], saved['id'])
            resolve.assert_not_called()

    def test_verification_failure_creates_no_listing(self):
        with patch.object(repository, 'resolve', return_value=self.identity()):
            draft = self.prepare()
        with patch.object(repository, 'resolve', side_effect=collector.CollectError('offline')):
            with self.assertRaises(app.ApiError) as error:
                self.confirm(draft)
        self.assertEqual(error.exception.code, 'COLLECT_FAILED')
        self.assertEqual(db.connect().execute('SELECT count(*) FROM app').fetchone()[0], 0)


class RepositoryResolverTest(unittest.TestCase):
    def test_github_uses_redirected_public_repository_id(self):
        with patch.object(collector, '_json', return_value=dict(id=42, private=False, full_name='owner/current')) as http:
            self.assertEqual(repository.resolve('owner/old', token='test-token'),
                dict(provider='github', remote_id=42, canonical_repo='owner/current'))
            http.assert_called_once_with('/repos/owner/old', token='test-token', timeout=5)

    def test_gitee_uses_url_path_and_never_receives_github_credentials(self):
        with patch.object(collector, '_repository_json', return_value=dict(id=42, private=False,
                full_name='用户/中文名称', html_url='https://gitee.com/owner/project')) as http:
            self.assertEqual(repository.resolve('gitee.com/owner/old', token='test-token'),
                dict(provider='gitee', remote_id=42, canonical_repo='gitee.com/owner/project'))
            http.assert_called_once_with('gitee.com/owner/old', timeout=5)

    def test_private_or_invalid_forge_identity_fails_closed(self):
        for data in [dict(id=42, private=True, full_name='o/r'), dict(id=True, private=False, full_name='o/r'),
                     dict(id=42, private=False, full_name='https://other/o/r')]:
            with patch.object(collector, '_json', return_value=data), self.assertRaises(collector.CollectError):
                repository.resolve('o/r')
