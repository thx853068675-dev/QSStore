"""Reply route and ownership tests using a temporary store and a real HTTP handler."""
import http.client
from http.server import ThreadingHTTPServer
import json
import tempfile
from threading import Thread, local
import unittest
from unittest.mock import patch

from server.hapstore import app, db, distribution


class ReviewReplyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        state = patch.multiple(db, DB_PATH=temporary.name + '/store.db', _local=local(), _initialized=False)
        state.start()
        self.addCleanup(state.stop)
        db.init_db()
        self.addCleanup(db.connect().close)
        self.app_id = db.upsert_app('example/first')
        self.other_id = db.upsert_app('example/second')
        db.put_review(self.app_id, 'alice', 'Alice', 5, 'Review')
        self.review_id = db.list_reviews(self.app_id)['items'][0]['id']
        self.review = f'/api/v1/apps/{self.app_id}/reviews/{self.review_id}'
        self.thread_path = self.review + '/replies'

        def identity(handler):
            account = handler.headers.get('Authorization', '').removeprefix('Bearer ')
            if account not in ('alice', 'bob'):
                raise app.ApiError(401, 'SIGN_IN_REQUIRED', 'Sign in')
            return account, account.title()

        for mock in (patch.object(app.Handler, '_identity', identity),
                     patch.object(distribution, 'country', return_value='CN'),
                     patch.object(app, '_rl', {})):
            mock.start()
            self.addCleanup(mock.stop)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), app.Handler)
        worker = Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True)
        worker.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, method, path, body=None, account=None):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        headers = {'Authorization': 'Bearer ' + account} if account else {}
        try:
            conn.request(method, path, json.dumps(body) if body is not None else None, headers)
            response = conn.getresponse()
            return response.status, json.load(response), response.getheader('Cache-Control')
        finally:
            conn.close()

    def test_reply_lifecycle_keeps_rating_and_parent_order_and_checks_ownership(self):
        invalid = {'body': ' '}
        self.assertEqual(self.request('POST', self.thread_path, invalid)[0], 401)
        self.assertEqual(self.request('POST', self.thread_path, invalid, 'bob')[0], 400)
        self.assertEqual(self.request('POST', self.thread_path, {'body': 'a' * 2001}, 'bob')[0], 400)
        status, response, cache = self.request('POST', self.thread_path,
            {'body': '  Great!  ', 'display_name': 'Spoof', 'stars': 1}, 'bob')
        self.assertEqual((status, cache), (201, 'no-store'))
        reply = response['data']['items'][0]
        self.assertEqual((reply['display_name'], reply['body'], reply['can_delete']), ('Bob', 'Great!', True))
        self.assertNotIn('stars', reply)
        self.assertNotIn('account_id', reply)
        db.sync_account_profile('bob', 'New Bob', 'https://example.com/bob.png')
        path = f"{self.thread_path}/{reply['id']}"
        public = self.request('GET', self.thread_path)[1]['data']
        self.assertFalse(public['items'][0]['can_delete'])
        self.assertEqual(public['items'][0]['display_name'], 'New Bob')
        self.assertEqual(public['items'][0]['avatar_url'], 'https://example.com/bob.png')
        self.assertEqual(self.request('DELETE', path, account='alice')[0], 404)
        self.assertEqual(self.request('POST', path + '/replies', {'body': 'Nested'}, 'bob')[0], 404)
        reviews = db.list_reviews(self.app_id)
        self.assertEqual(reviews['items'][0]['reply_count'], 1)
        self.assertEqual(reviews['summary'], {'count': 1, 'average': 5.0})
        status, response, _ = self.request('DELETE', path, account='bob')
        self.assertEqual((status, response['data']['total']), (200, 0))

    def test_pagination_and_app_boundary_and_cascade(self):
        wrong_app = f'/api/v1/apps/{self.other_id}/reviews/{self.review_id}/replies'
        self.assertEqual(self.request('GET', wrong_app)[0], 404)
        self.assertEqual(self.request('POST', wrong_app, {'body': 'Wrong app'}, 'bob')[0], 404)
        for i in range(11):
            self.assertTrue(db.put_review_reply(self.app_id, self.review_id, 'bob', 'Bob', str(i)))
        first = self.request('GET', self.thread_path)[1]['data']
        last = self.request('GET', self.thread_path + '?page=2')[1]['data']
        self.assertEqual((first['total'], len(first['items']), len(last['items'])), (11, 10, 1))
        last_id = last['items'][0]['id']
        self.assertEqual(self.request('DELETE', wrong_app + f'/{last_id}', account='bob')[0], 404)
        deleted = self.request('DELETE', f'{self.thread_path}/{last_id}?page=2', account='bob')[1]['data']
        self.assertEqual((deleted['page'], deleted['total']), (1, 10))
        self.assertEqual(self.request('DELETE', self.review, account='alice')[0], 200)
        self.assertEqual(self.request('GET', self.thread_path)[0], 404)
        self.assertEqual(db.connect().execute('SELECT COUNT(*) FROM review_reply').fetchone()[0], 0)

    def test_targets_show_only_for_replies_to_other_replies_in_the_same_thread(self):
        status, response, _ = self.request('POST', self.thread_path, {'body': 'Direct reply'}, 'bob')
        self.assertEqual(status, 201)
        self.assertTrue(response['data']['reply_targets_supported'])
        first = response['data']['items'][0]
        self.assertIsNone(first['reply_to_id'])
        self.assertEqual(first['reply_to_name'], '')

        db.put_review(self.app_id, 'bob', 'Bob', 4, 'Another discussion')
        other = next(row for row in db.list_reviews(self.app_id)['items'] if row['id'] != self.review_id)
        wrong_thread = f'/api/v1/apps/{self.app_id}/reviews/{other["id"]}/replies'
        addressed = {'body': 'Thanks, Bob', 'reply_to_id': first['id']}
        self.assertEqual(self.request('POST', wrong_thread, addressed, 'alice')[0], 404)
        for invalid in (True, '1', 0, 2**63):
            self.assertEqual(self.request('POST', self.thread_path,
                                         dict(addressed, reply_to_id=invalid), 'alice')[0], 400)

        status, response, _ = self.request('POST', self.thread_path, addressed, 'alice')
        self.assertEqual(status, 201)
        self.assertEqual(response['data']['total'], 2)
        reply = response['data']['items'][0]
        self.assertEqual((reply['body'], reply['reply_to_id'], reply['reply_to_name']),
                         ('Thanks, Bob', first['id'], 'Bob'))

        status, response, _ = self.request('DELETE', f'{self.thread_path}/{first["id"]}', account='bob')
        self.assertEqual(status, 200)
        remaining = response['data']['items'][0]
        self.assertEqual((remaining['id'], remaining['reply_to_id'], remaining['reply_to_name']),
                         (reply['id'], first['id'], ''))
        self.assertEqual(self.request('POST', self.thread_path, addressed, 'alice')[0], 404)

    def test_upgrade_preserves_existing_untargeted_replies(self):
        conn = db.connect()
        conn.execute('ALTER TABLE review_reply DROP COLUMN reply_to_id')
        conn.execute('ALTER TABLE review_reply DROP COLUMN device_model')
        conn.execute('ALTER TABLE review DROP COLUMN device_model')
        conn.execute("""INSERT INTO review_reply(review_id,account_id,display_name,body,created_at)
                        VALUES (?, 'bob', 'Bob', 'Before update', 10)""", (self.review_id,))
        conn.commit()
        db._initialized = False
        db.init_db()
        status, response, _ = self.request('GET', self.thread_path)
        self.assertEqual(status, 200)
        reply = response['data']['items'][0]
        self.assertEqual(reply['body'], 'Before update')
        self.assertIsNone(reply['reply_to_id'])
        self.assertEqual(reply['device_model'], '')
        self.assertEqual(db.list_reviews(self.app_id)['items'][0]['device_model'], '')

    def test_device_models_return_on_reviews_and_reply_previews(self):
        reviews = f'/api/v1/apps/{self.app_id}/reviews'
        status, response, _ = self.request('POST', reviews, {
            'stars': 4, 'body': 'Posted on a phone', 'device_model': '  HUAWEI Pura X  '
        }, 'bob')
        self.assertEqual(status, 200)
        recent = response['data']['items'][0]
        self.assertEqual(recent['device_model'], 'HUAWEI Pura X')

        for label, expected in [('MatePad Pro 13', 'MatePad Pro 13'), ('unknown', ''), ('a\nb', '')]:
            status, response, _ = self.request('POST', self.thread_path, {
                'body': 'Reply', 'device_model': label
            }, 'bob')
            self.assertEqual(status, 201)
            self.assertEqual(response['data']['items'][0]['device_model'], expected)

        listed = self.request('GET', reviews + '?reply_preview=1')[1]['data']['items']
        by_id = {row['id']: row for row in listed}
        self.assertEqual(by_id[recent['id']]['device_model'], 'HUAWEI Pura X')
        self.assertEqual(by_id[self.review_id]['device_model'], '')
        self.assertEqual([row['device_model'] for row in by_id[self.review_id]['reply_preview']],
                         ['MatePad Pro 13', '', ''])

    def test_three_oldest_preview_and_chronological_paging_preserve_legacy_order(self):
        for index in range(12):
            db.put_review_reply(self.app_id, self.review_id, 'bob', 'Bob', str(index))
        db.put_review(self.app_id, 'bob', 'Bob', 4, 'Other thread')
        other = next(row for row in db.list_reviews(self.app_id)['items'] if row['id'] != self.review_id)
        db.put_review_reply(self.app_id, other['id'], 'alice', 'Alice', 'Independent')

        reviews = f'/api/v1/apps/{self.app_id}/reviews'
        legacy = self.request('GET', reviews)[1]['data']['items']
        self.assertTrue(all('reply_preview' not in row for row in legacy))
        status, response, _ = self.request('GET', reviews + '?reply_preview=1')
        self.assertEqual(status, 200)
        items = {row['id']: row for row in response['data']['items']}
        preview = items[self.review_id]['reply_preview']
        self.assertEqual([row['body'] for row in preview], ['0', '1', '2'])
        self.assertTrue(all(not row['can_delete'] and 'account_id' not in row for row in preview))
        self.assertEqual([row['body'] for row in items[other['id']]['reply_preview']], ['Independent'])
        mine = self.request('GET', f'/api/v1/me/apps/{self.app_id}/reviews?reply_preview=1', account='bob')[1]
        own_preview = next(row['reply_preview'] for row in mine['data']['items'] if row['id'] == self.review_id)
        self.assertTrue(all(row['can_delete'] for row in own_preview))

        recent = self.request('GET', self.thread_path)[1]['data']['items']
        self.assertEqual(recent[0]['body'], '11')
        first = self.request('GET', self.thread_path + '?order=asc')[1]['data']
        self.assertEqual([row['body'] for row in first['items']], [str(i) for i in range(10)])
        last = self.request('POST', self.thread_path + '?order=asc&page=last',
                            {'body': 'New reply'}, 'alice')[1]['data']
        self.assertEqual((last['page'], [row['body'] for row in last['items']]), (2, ['10', '11', 'New reply']))
        self.assertEqual([row['id'] for row in last['reply_preview']], [row['id'] for row in preview])
        url = f"{self.thread_path}/{preview[0]['id']}?order=asc"
        after = self.request('DELETE', url, account='bob')[1]['data']
        self.assertEqual([row['body'] for row in after['reply_preview']], ['1', '2', '3'])
