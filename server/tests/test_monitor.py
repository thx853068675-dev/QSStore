"""Private metrics require the owner's password; refreshes cache GitHub usage."""

import base64
import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from unittest.mock import patch

from server.hapstore import app, monitor


class MonitorEndpointTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.password = 'monitor-test-password'
        cls.verifier = monitor.hash_password(cls.password)

    def setUp(self):
        self.rates = patch.object(app, '_rl', {})
        self.rates.start()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), app.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}/api/v1/monitor'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.rates.stop()

    def header(self, password, username='monitor'):
        return 'Basic ' + base64.b64encode(f'{username}:{password}'.encode()).decode()

    def test_private_metrics_require_correct_password(self):
        with patch.object(app, 'MONITOR_PASSWORD_HASH', self.verifier), \
             patch.object(monitor, 'snapshot', return_value={'system': {'disk_available_bytes': 123}}) as snap:
            for credential in (None, 'Bearer old-random-token', self.header('incorrect'),
                               self.header(self.password, 'other'), 'Basic !!!'):
                headers = {} if credential is None else {'Authorization': credential}
                with self.assertRaises(urllib.error.HTTPError) as denied:
                    urllib.request.urlopen(urllib.request.Request(self.url, headers=headers))
                self.assertEqual(denied.exception.code, 401)
            snap.assert_not_called()
            for credential in (self.header(self.password), 'Bearer ' + self.password):
                request = urllib.request.Request(self.url, headers={'Authorization': credential})
                with urllib.request.urlopen(request) as response:
                    body = json.load(response)
                    self.assertEqual(response.headers['Cache-Control'], 'no-store')
                self.assertEqual(body['data']['system']['disk_available_bytes'], 123)
            self.assertEqual(snap.call_count, 2)

    def test_disabled_without_valid_password_configuration(self):
        for value in ('', 'invalid', 'pbkdf2_sha256$999999999$' + 'a' * 32 + '$' + 'b' * 64):
            with patch.object(app, 'MONITOR_PASSWORD_HASH', value):
                with self.assertRaises(urllib.error.HTTPError) as denied:
                    urllib.request.urlopen(self.url)
                self.assertEqual(denied.exception.code, 503)

    def test_monitor_attempts_have_their_own_limit(self):
        with patch.object(app, 'MONITOR_PASSWORD_HASH', self.verifier), \
             patch.object(monitor, 'snapshot') as snap:
            for _ in range(10):
                with self.assertRaises(urllib.error.HTTPError) as denied:
                    urllib.request.urlopen(self.url)
                self.assertEqual(denied.exception.code, 401)
            with self.assertRaises(urllib.error.HTTPError) as limited:
                urllib.request.urlopen(self.url)
            self.assertEqual(limited.exception.code, 429)
            self.assertEqual(limited.exception.headers['Retry-After'], '60')
            snap.assert_not_called()
            with urllib.request.urlopen(self.url.replace('/monitor', '/healthz')) as response:
                self.assertEqual(response.status, 200)


class PasswordVerifierTest(unittest.TestCase):
    def test_verifier_is_salted_and_not_the_password(self):
        password = 'another-test-password'
        first, second = monitor.hash_password(password), monitor.hash_password(password)
        self.assertNotEqual(first, second)
        self.assertNotIn(password, first)
        self.assertTrue(monitor.verify_authorization('Bearer ' + password, first))
        self.assertFalse(monitor.verify_authorization('Bearer incorrect', first))

    def test_unicode_password_and_colons_are_preserved(self):
        password = '测试:password'
        verifier = monitor.hash_password(password)
        header = 'Basic ' + base64.b64encode(('monitor:' + password).encode()).decode()
        self.assertTrue(monitor.verify_authorization(header, verifier))
        self.assertFalse(monitor.verify_authorization('Basic /w==', verifier))
        self.assertFalse(monitor.verify_authorization('Bearer ' + 'x' * 3000, verifier))


class GithubCacheTest(unittest.TestCase):
    def test_refreshes_only_after_cache_expires(self):
        with patch.object(monitor, '_GITHUB_CACHE', {}), \
             patch.object(monitor, '_GITHUB_CACHE_AT', 0), \
             patch.object(monitor, '_fetch_github', return_value={'ok': True, 'resources': {}}) as fetch:
            self.assertTrue(monitor.github_snapshot('token')['ok'])
            self.assertTrue(monitor.github_snapshot('token')['ok'])
            fetch.assert_called_once_with('token')


if __name__ == '__main__':
    unittest.main()
