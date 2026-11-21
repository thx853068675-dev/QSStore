"""Developer enrollment, GitHub verification and review ownership through HTTP."""
import http.client
from http.server import ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import tempfile
from threading import Thread, local
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from server.hapstore import app, db, developer_registry as registry, distribution, github_association


class DeveloperRegistryTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        mocks = (patch.multiple(db, DB_PATH=str(Path(temporary.name) / 'store.db'), _local=local(), _initialized=False),
                 patch.object(app.Handler, '_identity', self.identity),
                 patch.object(distribution, 'country', return_value='CN'),
                 patch.object(app, '_rl', {}),
                 patch.object(registry, '_github', self.github),
                 patch.object(github_association, '_github_user', self.github_user),
                 patch.dict(os.environ, {
                     'HAPSTORE_GITHUB_OAUTH_CLIENT_ID': 'test-client',
                     'HAPSTORE_GITHUB_OAUTH_CLIENT_SECRET': 'test-secret',
                     'HAPSTORE_GITHUB_OAUTH_CALLBACK': 'https://store.example.invalid' + github_association.CALLBACK,
                 }))
        for mock in mocks:
            mock.start()
            self.addCleanup(mock.stop)
        db.init_db()
        self.addCleanup(db.connect().close)
        self.app_id = db.upsert_app('owner/project')
        db.set_publisher(self.app_id, 'publisher', 'Publisher')
        self.app = f'/api/v1/apps/{self.app_id}'
        self.center = '/api/v1/me/developer'
        self.claim = self.app + '/claim'
        self.release = f'{self.center}/claims/{self.app_id}'
        self.remote_id = 117
        self.created = '2020-02-03T00:00:00Z'
        self.github_user_id = 888
        self.exchanges = 0
        self.association = self.center + '/github'
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), app.Handler)
        worker = Thread(target=self.server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        worker.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    @staticmethod
    def identity(handler):
        account = handler.headers.get('Authorization', '').removeprefix('Bearer ')
        if account not in ('alice', 'bob', 'publisher'):
            raise app.ApiError(401, 'SIGN_IN_REQUIRED', 'Sign in')
        return account, account.title()

    def github(self, path, token, *, missing=False):
        if path in ('/repos/owner/project', '/repos/owner/renamed', '/repos/owner/second',
                    '/repos/other/project', '/repos/org/project'):
            remote_id = self.remote_id if path.endswith(('owner/project', 'renamed')) else {
                '/repos/owner/second': 118, '/repos/other/project': 119, '/repos/org/project': 120
            }[path]
            return {'id': remote_id, 'full_name': path.removeprefix('/repos/'),
                    'private': False, 'created_at': self.created,
                    'owner': {'id': 889 if path.startswith('/repos/other/') else 888,
                              'type': 'Organization' if path.startswith('/repos/org/') else 'User'}}
        raise AssertionError(path)

    def github_user(self, config, code, verifier):
        self.exchanges += 1
        self.assertEqual(code, 'signed-from-github')
        self.assertEqual(len(verifier), 43)
        return self.github_user_id, 'owner'

    def browser(self, path, expected=200, method='GET'):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=4)
        try:
            conn.request(method, path)
            response = conn.getresponse()
            self.assertEqual(response.status, expected)
            self.assertEqual(response.getheader('Cache-Control'), 'no-store')
            self.assertEqual(response.getheader('Referrer-Policy'), 'no-referrer')
            return response.read().decode()
        finally:
            conn.close()

    def begin_auth(self, account='alice'):
        self.request('POST', self.center, {}, account)
        result = self.request('POST', self.association + '/start', {}, account)
        parsed = urlsplit(result['authorization_url'])
        self.assertEqual((parsed.netloc, parsed.path), ('github.com', '/login/oauth/authorize'))
        fields = parse_qs(parsed.query)
        self.assertNotIn('scope', fields)
        self.assertNotIn('client_secret', fields)
        self.assertEqual(fields['code_challenge_method'], ['S256'])
        return github_association.CALLBACK + '?code=signed-from-github&state=' + fields['state'][0]

    def authorize(self, account='alice'):
        callback = self.begin_auth(account)
        page = self.browser(callback)
        receipt = re.search(r'qingqi-installer://github-link\?receipt=([A-Za-z0-9_-]{43})', page)
        self.assertIsNotNone(receipt)
        self.assertNotIn('signed-from-github', page)
        return {'receipt': receipt[1]}

    def claim_as_alice(self):
        proof = self.authorize()
        self.request('POST', self.association + '/confirm', proof, 'alice')
        self.assertEqual(self.request('POST', self.claim, {'action': 'github'}, 'alice'), {'status': 'mine'})

    def request(self, method, path, body=None, account=None, expected=200):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=4)
        headers = {'Authorization': 'Bearer ' + account} if account else {}
        try:
            conn.request(method, path, json.dumps(body) if body is not None else None, headers)
            response = conn.getresponse()
            payload = json.load(response)
            self.assertEqual(expected, response.status, payload)
            if account:
                self.assertEqual(response.getheader('Cache-Control'), 'no-store')
            return payload.get('data', payload.get('error'))
        finally:
            conn.close()

    def test_browser_authorization_is_single_use_and_bound_to_initiating_account(self):
        self.request('GET', self.association, expected=401)
        original = self.begin_auth()
        self.browser(original, expected=405, method='HEAD')
        data = self.authorize()
        self.browser(original, expected=400)
        # Completion in the browser cannot itself attach the account.
        self.assertEqual(self.request('GET', self.association, account='alice')['login'], '')
        self.request('POST', self.association + '/confirm', data, 'bob', 409)
        self.assertEqual(self.request('POST', self.association + '/confirm', data, 'alice')['login'], 'owner')
        self.request('POST', self.association + '/confirm', data, 'alice', 409)
        self.request('POST', self.association + '/start', {}, 'alice', 409)
        other = self.authorize('bob')
        self.request('POST', self.association + '/confirm', other, 'bob', 409)
        factory = self.begin_auth('publisher')
        with db.connect() as conn:
            conn.execute("UPDATE developer_github_flow SET expires_at=0 WHERE account_id='publisher'")
        self.browser(factory, expected=400)

    def test_binding_verifies_multiple_owned_repositories_and_refuses_others(self):
        self.claim_as_alice()
        self.assertEqual(self.exchanges, 1)
        second = db.upsert_app('owner/second')
        self.request('POST', f'/api/v1/apps/{second}/claim', {'action': 'github'}, 'alice')
        self.assertEqual(len(self.request('GET', self.center, account='alice')['items']), 2)
        self.assertEqual(self.exchanges, 1)
        self.assertEqual(db.publisher_account_id(self.app_id), 'alice')
        self.assertEqual({row['id'] for row in db.list_published_by_account('alice')}, {self.app_id, second})
        self.assertEqual(db.list_published_by_account('publisher'), [])
        for repo in ('other/project', 'org/project'):
            rejected = db.upsert_app(repo)
            self.request('POST', f'/api/v1/apps/{rejected}/claim', {'action': 'github'}, 'alice', 403)
        duplicate = db.upsert_app('owner/renamed')
        self.request('POST', f'/api/v1/apps/{duplicate}/claim', {'action': 'github'}, 'alice', 409)
        self.request('DELETE', self.association, account='alice')
        self.assertEqual(self.request('GET', self.claim, account='alice')['status'], 'mine')
        self.request('POST', f'/api/v1/apps/{duplicate}/claim', {'action': 'github'}, 'alice', 409)

    def test_handoff_migrates_existing_claim_and_unlisting_keeps_history(self):
        db.put_review(self.app_id, 'bob', 'Bob', 4, 'Existing review')
        self.claim_as_alice()
        self.request('DELETE', '/api/v1/me/apps/' + str(self.app_id), account='publisher', expected=403)
        with db.connect() as conn:
            conn.execute("UPDATE publisher SET account_id='publisher',display_name='Publisher' WHERE app_id=?",
                         (self.app_id,))
        registry.migrate_claimed_publishers(db.connect())
        registry.migrate_claimed_publishers(db.connect())
        self.assertEqual(db.publisher_account_id(self.app_id), 'alice')
        self.assertEqual(db.connect().execute('SELECT count(*) FROM publisher WHERE app_id=?', (self.app_id,))
                         .fetchone()[0], 1)
        self.request('DELETE', '/api/v1/me/apps/' + str(self.app_id), account='alice')
        self.assertEqual(db.get_app(self.app_id)['status'], 'hidden')
        self.assertEqual(db.review_summary(self.app_id)['count'], 1)
        self.assertEqual(app._repo_owner_state('owner/project', 'publisher')['state'], 'other')
        self.assertEqual(app._repo_owner_state('owner/project', 'alice')['app_id'], self.app_id)

    def test_native_redirect_requires_authenticated_initiating_account(self):
        with patch.dict(os.environ, {'HAPSTORE_GITHUB_OAUTH_CALLBACK': github_association.NATIVE_CALLBACK}):
            callback = self.begin_auth()
            params = parse_qs(urlsplit(callback).query)
            body = {key: params[key][0] for key in ('code', 'state')}
            self.browser(callback, expected=400)
            self.request('POST', self.association + '/confirm', body, 'bob', 400)
            self.assertEqual(self.exchanges, 0)
            result = self.request('POST', self.association + '/confirm', body, 'alice')
            self.assertEqual(result['login'], 'owner')
            self.request('POST', self.association + '/confirm', body, 'alice', 400)
            self.assertEqual(self.exchanges, 1)
            self.assertEqual(self.request('POST', self.claim, {'action': 'github'}, 'alice'), {'status': 'mine'})

    def test_binding_can_start_directly_without_opening_developer_center(self):
        self.assertFalse(registry.enrolled(db.connect(), 'alice'))
        flow = self.request('POST', self.association + '/start', {}, 'alice')
        self.assertTrue(flow['authorization_url'].startswith('https://github.com/login/oauth/authorize?'))
        self.assertTrue(registry.enrolled(db.connect(), 'alice'))

    def test_owner_configuration_round_trip_detects_stale_edits(self):
        url = f'/api/v1/me/apps/{self.app_id}/configuration'
        save = f'/api/v1/me/apps/{self.app_id}/category'
        self.request('GET', url, expected=401)
        self.request('GET', url, account='alice', expected=403)
        original = self.request('GET', url, account='publisher')
        body = {'expected_configuration': original['configuration'], 'category': '工具',
                'presentation': {'display_name': '已编辑', 'description': '新应用介绍'}}
        saved = self.request('POST', save, body, 'publisher')
        self.assertNotEqual(saved['configuration'], original['configuration'])
        self.assertEqual(saved['app']['display_name'], '已编辑')
        self.assertEqual(saved['app']['description'], '新应用介绍')
        self.assertEqual(saved['app']['screenshots'], [])
        self.assertEqual(self.request('GET', url, account='publisher'), saved)
        self.assertEqual(self.request('GET', self.app)['display_name'], '已编辑')
        self.request('POST', save, body, 'publisher', 409)
        self.claim_as_alice()
        result = self.request('GET', url, account='alice')
        self.assertTrue(result['app']['claimed_by_me'])
        self.assertTrue(self.request('GET', f'/api/v1/me/apps/{self.app_id}/reviews', account='alice')['claimed_by_me'])
        self.request('GET', url, account='publisher', expected=403)
    def test_file_flow_is_retired_and_reused_repo_paths_are_rejected(self):
        self.request('POST', self.claim, {'action': 'start'}, 'alice', 409)
        self.request('POST', self.claim, {'action': 'verify'}, 'alice', 409)
        proof = self.authorize()
        self.request('POST', self.association + '/confirm', proof, 'alice')
        self.created = '2099-01-01T00:00:00Z'
        self.request('POST', self.claim, {'action': 'github'}, 'alice', 409)
        forge = db.upsert_app('gitee.com/owner/project')
        self.assertEqual(self.request('GET', f'/api/v1/apps/{forge}/claim', account='alice')['status'], 'unsupported')

    def test_current_publisher_can_moderate_and_only_claimant_replies_as_developer(self):
        db.put_review(self.app_id, 'bob', 'Bob', 4, 'My experience')
        review = db.list_reviews(self.app_id)['items'][0]['id']
        review_path = f'{self.app}/reviews/{review}'
        visibility = review_path + '/visibility?reply_preview=1'
        self.request('POST', visibility, {'hidden': True}, expected=401)
        before = self.request('GET', f'/api/v1/me/apps/{self.app_id}/reviews', account='publisher')
        self.assertTrue(before['can_moderate'])
        self.request('POST', visibility, {'hidden': True}, 'publisher')
        self.request('POST', visibility, {'hidden': False}, 'publisher')
        self.claim_as_alice()
        self.request('POST', visibility, {'hidden': True, 'account_id': 'alice'}, 'publisher', 403)
        self.request('POST', visibility, {'hidden': 1}, 'alice', 400)
        self.request('POST', visibility, {'hidden': True}, 'alice')
        public = self.request('GET', self.app + '/reviews')
        self.assertEqual(public['items'][0]['body'], '')
        self.assertTrue(public['items'][0]['hidden'])
        self.assertFalse(public['can_moderate'])
        self.assertEqual(public['summary'], {'count': 1, 'average': 4.0})
        author = self.request('GET', f'/api/v1/me/apps/{self.app_id}/reviews', account='bob')
        self.assertEqual(author['items'][0]['body'], 'My experience')
        self.assertFalse(author['can_moderate'])
        self.request('DELETE', review_path, account='alice', expected=404)
        self.request('POST', review_path + '/replies', {'body': 'Thanks'}, 'alice', 201)
        reply = self.request('POST', review_path + '/replies',
                             {'body': 'Again', 'is_developer': True}, 'bob', 201)['items']
        self.assertEqual([(r['body'], r['is_developer']) for r in reply], [('Again', False), ('Thanks', True)])
        self.request('POST', visibility, {'hidden': False}, 'alice')
        self.assertEqual(self.request('GET', self.app + '/reviews')['items'][0]['body'], 'My experience')
        self.request('DELETE', self.release, account='alice')
        self.request('POST', visibility, {'hidden': True}, 'alice')
        self.assertFalse(any(r['is_developer'] for r in self.request('GET', review_path + '/replies')['items']))
        self.assertEqual(self.request('GET', self.center, account='alice')['items'], [])

    def test_disabled_configuration_and_hidden_listing(self):
        with patch.dict(os.environ, {'HAPSTORE_GITHUB_OAUTH_CLIENT_ID': ''}):
            self.assertFalse(self.request('GET', self.association, account='alice')['enabled'])
            self.request('POST', self.association + '/start', {}, 'alice', 503)
        self.claim_as_alice()
        with db.connect() as conn:
            conn.execute("UPDATE app SET status='hidden' WHERE id=?", (self.app_id,))
        self.request('GET', self.claim, account='alice', expected=404)
