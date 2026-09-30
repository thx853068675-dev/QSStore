"""Verified account quotas and reuse of expensive Release preprocessing."""

import os
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from server.hapstore import app, collector, db


class SubmitLimitsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_db = db.DB_PATH
        db.DB_PATH = os.path.join(self.tmp.name, "store.db")
        db._local = threading.local()
        db._initialized = False
        db.init_db()
        with app._rl_lock:
            app._rl.clear()
        self.meta = patch.object(collector, "fetch_app_metadata", return_value={
            "display_name": "Test app", "description": "description", "category": "工具"})
        self.releases = patch.object(collector, "fetch_releases", return_value=[{
            "tag": "v1", "assets": [{"name": "main.hap", "size": 100}]}])
        self.enrich = patch.object(collector, "enrich_assets_with_hap_metadata")
        self.metadata_call = self.meta.start()
        self.releases_call = self.releases.start()
        self.enrich.start()
        self.addCleanup(self.meta.stop)
        self.addCleanup(self.releases.stop)
        self.addCleanup(self.enrich.stop)

    def tearDown(self):
        db.connect().close()
        db.DB_PATH = self.old_db
        db._local = threading.local()
        db._initialized = False
        with app._rl_lock:
            app._rl.clear()
        self.tmp.cleanup()

    def prepare(self, repo="owner/repo", account="account-a"):
        return app.h_submit_prepare({"repo_url": "https://github.com/" + repo},
                                    "shared-network", (account, "Nickname"))

    def test_three_checks_per_minute_and_exact_retry_time(self):
        with patch.object(app.time, "time", return_value=1000):
            for i in range(3):
                self.prepare(f"owner/repo{i}")
        with patch.object(app.time, "time", return_value=1012):
            with self.assertRaises(app.ApiError) as failure:
                self.prepare("owner/repo3")
            self.assertEqual(failure.exception.status, 429)
            self.assertEqual(failure.exception.retry_after, 48)
            self.assertIn("48 秒", failure.exception.message)
        with patch.object(app.time, "time", return_value=1060):
            self.assertTrue(self.prepare("owner/repo3")["choices"])

    def test_accounts_sharing_an_ip_have_separate_quotas(self):
        for i in range(3):
            self.prepare(f"owner/repo{i}")
        other = self.prepare("owner/repo0", "account-b")
        self.assertIsNotNone(db.get_submit_draft(other["draft_token"], "account-b"))
        self.assertIsNone(db.get_submit_draft(other["draft_token"], "account-a"))

    def test_invalid_addresses_do_not_consume_quota(self):
        for _ in range(4):
            with self.assertRaises(app.ApiError) as failure:
                app.h_submit_prepare({"repo_url": "not a repo"}, "shared-network",
                                     ("account-a", "Nickname"))
            self.assertEqual(failure.exception.code, "INVALID_REPO_URL")
        for i in range(3):
            self.prepare(f"owner/repo{i}")
        self.assertEqual(self.metadata_call.call_count, 3)

    def test_repeat_check_reuses_draft_even_after_quota_is_full(self):
        original = self.prepare()
        self.prepare("owner/second")
        self.prepare("owner/third")
        repeated = self.prepare("OWNER/REPO")
        self.assertEqual(original["draft_token"], repeated["draft_token"])
        self.assertEqual(repeated["description"], "description")
        self.assertEqual(self.releases_call.call_count, 3)
        app.h_submit_prepare({"repo_url": "https://github.com/owner/repo"},
                             "different-network", ("account-a", "Nickname"))
        self.assertEqual(self.metadata_call.call_count, 3)

    def test_old_cached_result_is_collected_again(self):
        with patch.object(app.time, "time", return_value=1000):
            original = self.prepare()
        with patch.object(app.time, "time", return_value=1301):
            updated = self.prepare()
        self.assertNotEqual(original["draft_token"], updated["draft_token"])
        self.assertEqual(self.releases_call.call_count, 2)

    def test_retry_header_uses_error_wait(self):
        handler = app.Handler.__new__(app.Handler)
        handler._send = Mock()
        handler._error(429, "RATE_LIMITED", "wait", retry_after=48)
        self.assertEqual(handler._send.call_args.args[3], {"Retry-After": "48"})

    def test_existing_draft_table_migrates_without_losing_choices(self):
        conn = db.connect()
        conn.execute("DROP TABLE submit_draft")
        conn.execute("""CREATE TABLE submit_draft (
            token TEXT PRIMARY KEY, repo TEXT NOT NULL, account_id TEXT NOT NULL,
            choices_json TEXT NOT NULL, suggested_category TEXT NOT NULL,
            expires_at INTEGER NOT NULL)""")
        conn.execute("INSERT INTO submit_draft VALUES (?,?,?,?,?,?)",
                     ("legacy", "owner/repo", "account-a", '[]', "工具", 9999999999))
        conn.commit()
        db._initialized = False
        db.init_db()
        self.assertEqual(db.get_submit_draft("legacy", "account-a")["choices"], [])
        self.assertIsNone(db.recent_submit_draft("owner/repo", "account-a"))
        self.assertTrue(self.prepare()["choices"])


if __name__ == "__main__":
    unittest.main()
