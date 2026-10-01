"""Old client contract, fast listing, and durable background lifecycle."""
import copy
import io
import json
import os
import tempfile
import threading
import unittest
import zipfile
from unittest.mock import patch

from PIL import Image
from server.hapstore import app, collector, db, submissions


class BackgroundSubmitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_db = db.DB_PATH
        db.DB_PATH = os.path.join(self.tmp.name, "store.db")
        db._local = threading.local()
        db._initialized = False
        db.init_db()
        with app._rl_lock:
            app._rl.clear()
        self.meta = {"display_name": "Repository", "description": "desc", "category": "工具"}
        self.releases = [{
            "tag": "v2", "name": "Version 2", "published_at": "2026-10-01",
            "assets": [
                {"name": "main-v2.hap", "size": 100, "sha256": "a" * 64,
                 "download_url": "https://github.com/o/r/releases/download/v2/main-v2.hap"},
                {"name": "helper.hap", "size": 90, "sha256": "b" * 64,
                 "download_url": "https://github.com/o/r/releases/download/v2/helper.hap"},
            ]}, {
            "tag": "v1", "name": "Version 1", "published_at": "2026-09-01",
            "assets": [{"name": "main-v1.hap", "size": 80, "sha256": "c" * 64,
                        "download_url": "https://github.com/o/r/releases/download/v1/main-v1.hap"}],
        }]
        self.metadata_mock = patch.object(collector, "fetch_app_metadata",
                                          side_effect=lambda *a, **k: copy.deepcopy(self.meta))
        self.releases_mock = patch.object(collector, "fetch_releases",
                                          side_effect=lambda *a, **k: copy.deepcopy(self.releases))
        self.fetch_meta = self.metadata_mock.start()
        self.fetch_releases = self.releases_mock.start()
        self.addCleanup(self.metadata_mock.stop)
        self.addCleanup(self.releases_mock.stop)

    def tearDown(self):
        db.connect().close()
        db.DB_PATH = self.old_db
        db._local = threading.local()
        db._initialized = False
        self.tmp.cleanup()

    def prepare(self, repo="o/r"):
        return app.h_submit_prepare({"repo_url": "https://github.com/" + repo},
                                    "shared-ip", ("uid", "Nickname"))

    def confirm(self, draft, name="main-v2.hap", category="工具"):
        return app.h_submit_confirm({"draft_token": draft["draft_token"],
            "asset_name": name, "category": category}, ("uid", "Nickname"))

    def enrich(self, releases, **kwargs):
        for release in releases:
            for asset in release["assets"]:
                asset.update(bundle_name="com.test.helper" if "helper" in asset["name"]
                    else "com.test.main", version_name=release["tag"][1:],
                    version_code=int(release["tag"][1:]), min_api=12,
                    display_name="Helper" if "helper" in asset["name"] else "Actual App")
                asset["_icon"] = ("image/png", b"verified-icon")

    def task(self, app_id):
        return dict(db.connect().execute("SELECT * FROM catalog_task WHERE app_id=?",
                                         (app_id,)).fetchone())

    def test_prepare_and_confirm_never_download_or_rescan_github(self):
        with patch.object(collector, "enrich_assets_with_hap_metadata",
                          side_effect=AssertionError("foreground download")):
            draft = self.prepare()
            self.assertEqual([a["name"] for a in draft["choices"]],
                             ["main-v2.hap", "helper.hap"])
            self.assertNotIn("snapshot", draft)
            result = self.confirm(draft)
        app_id = result["app"]["id"]
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["app"]["publisher_name"], "Nickname")
        self.assertEqual(db.list_releases(app_id)["items"][0]["assets"][0]["name"], "main-v2.hap")
        self.assertEqual(self.fetch_meta.call_count, 1)
        self.assertEqual(self.fetch_releases.call_count, 1)
        self.assertEqual(self.task(app_id)["status"], "pending")
        self.assertIsNone(db.connect().execute("SELECT id FROM app WHERE id<>?",
                                              (app_id,)).fetchone())

    def test_worker_populates_name_icon_identity_and_only_selected_bundle_history(self):
        result = self.confirm(self.prepare())
        app_id = result["app"]["id"]
        with patch.object(collector, "enrich_assets_with_hap_metadata", side_effect=self.enrich):
            self.assertTrue(submissions.process_one())
        details = db.get_app(app_id)
        self.assertEqual(details["display_name"], "Actual App")
        self.assertEqual(details["latest_asset"]["bundle_name"], "com.test.main")
        self.assertEqual(db.app_icon(app_id), ("image/png", b"verified-icon"))
        self.assertEqual(self.task(app_id)["status"], "done")
        releases = db.list_releases(app_id)["items"]
        self.assertEqual([r["tag"] for r in releases], ["v2", "v1"])
        self.assertEqual([a["name"] for r in releases for a in r["assets"]],
                         ["main-v2.hap", "main-v1.hap"])
        self.assertEqual(db.get_app_selection(app_id)["bundle_name"], "com.test.main")
        self.assertEqual(self.fetch_releases.call_count, 1)

    def test_helper_selection_does_not_publish_main_package(self):
        app_id = self.confirm(self.prepare(), "helper.hap")["app"]["id"]
        with patch.object(collector, "enrich_assets_with_hap_metadata", side_effect=self.enrich):
            submissions.process_one()
        self.assertEqual(db.get_app(app_id)["display_name"], "Helper")
        self.assertEqual(db.get_app(app_id)["latest_asset"]["bundle_name"], "com.test.helper")
        self.assertEqual([a["name"] for r in db.list_releases(app_id)["items"]
                          for a in r["assets"]], ["helper.hap"])

    def test_background_failure_keeps_listing_and_schedules_retry(self):
        app_id = self.confirm(self.prepare())["app"]["id"]
        with patch.object(collector, "enrich_assets_with_hap_metadata", side_effect=OSError("offline")):
            submissions.process_one()
        task = self.task(app_id)
        self.assertEqual(task["status"], "pending")
        self.assertEqual(task["attempts"], 1)
        self.assertGreater(task["next_attempt"], 0)
        self.assertEqual(db.get_app(app_id)["status"], "published")
        self.assertEqual(db.list_releases(app_id)["items"][0]["assets"][0]["name"], "main-v2.hap")
        db.connect().execute("UPDATE catalog_task SET next_attempt=0")
        db.connect().commit()
        with patch.object(collector, "enrich_assets_with_hap_metadata", side_effect=self.enrich):
            submissions.process_one()
        self.assertEqual(self.task(app_id)["status"], "done")
        self.assertEqual(db.get_app(app_id)["sync_error"], "")

    def test_repeated_confirmation_is_idempotent_and_preserves_later_category(self):
        draft = self.prepare()
        first = self.confirm(draft)
        app_id = first["app"]["id"]
        db.configure_published_app(app_id, "uid", "游戏")
        second = self.confirm(draft)
        self.assertEqual(second["app"]["id"], app_id)
        self.assertEqual(second["app"]["category"], "游戏")
        self.assertEqual(self.task(app_id)["generation"], 1)
        self.assertEqual(db.connect().execute("SELECT count(*) FROM catalog_task").fetchone()[0], 1)

    def test_completed_confirmation_does_not_republish_after_unlisting(self):
        draft = self.prepare()
        app_id = self.confirm(draft)["app"]["id"]
        app.h_remove_my_app(str(app_id), ("uid", "Nickname"))
        with self.assertRaises(app.ApiError) as failure:
            self.confirm(draft)
        self.assertEqual(failure.exception.code, "APP_UNLISTED")
        self.assertEqual(db.get_app(app_id)["status"], "hidden")

    def test_user_can_relist_same_repo_and_change_category(self):
        draft = self.prepare()
        app_id = self.confirm(draft)["app"]["id"]
        app.h_remove_my_app(str(app_id), ("uid", "Nickname"))
        fresh = self.prepare("O/R")
        self.assertEqual(fresh["existing"]["state"], "new")
        result = self.confirm(fresh, category="影音")
        self.assertEqual(result["app"]["id"], app_id)
        self.assertEqual(result["app"]["status"], "published")
        self.assertEqual(result["app"]["category"], "影音")
        self.assertEqual(self.task(app_id)["generation"], 2)

    def test_user_can_list_new_address_after_old_address_unlisted(self):
        old_id = self.confirm(self.prepare())["app"]["id"]
        app.h_remove_my_app(str(old_id), ("uid", "Nickname"))
        new_id = self.confirm(self.prepare("o/new-repo"))["app"]["id"]
        self.assertNotEqual(old_id, new_id)
        self.assertEqual(db.get_app(old_id)["status"], "hidden")
        self.assertEqual(db.get_app(new_id)["status"], "published")

    def test_unlisted_repo_can_be_published_by_another_account(self):
        first_draft = self.prepare()
        app_id = self.confirm(first_draft)["app"]["id"]
        db.put_review(app_id, "reviewer", "Reviewer", 5, "Keep this comment")
        app.h_remove_my_app(str(app_id), ("uid", "Nickname"))
        fresh = app.h_submit_prepare({"repo_url": "https://github.com/O/R"},
                                     "shared-ip", ("new-owner", "New publisher"))
        self.assertEqual(fresh["existing"]["state"], "new")
        result = app.h_submit_confirm({"draft_token": fresh["draft_token"],
            "asset_name": "helper.hap", "category": "影音"}, ("new-owner", "New publisher"))
        self.assertEqual(result["app"]["id"], app_id)
        self.assertEqual(result["app"]["publisher_name"], "New publisher")
        self.assertEqual(db.publisher_account_id(app_id), "new-owner")
        self.assertEqual(db.list_published_by_account("uid"), [])
        self.assertEqual(len(db.list_published_by_account("new-owner")), 1)
        self.assertEqual(db.review_summary(app_id)["count"], 1)
        with self.assertRaises(app.ApiError) as denied:
            self.confirm(first_draft)
        self.assertEqual(denied.exception.status, 403)
        for operation in (
            lambda: app.h_remove_my_app(str(app_id), ("uid", "Nickname")),
            lambda: app.h_configure_my_app(str(app_id), {"category": "游戏"}, ("uid", "Nickname")),
        ):
            with self.assertRaises(app.ApiError) as failure:
                operation()
            self.assertEqual(failure.exception.status, 403)

    def test_in_race_only_one_account_can_claim_unlisted_repo(self):
        app_id = self.confirm(self.prepare())["app"]["id"]
        app.h_remove_my_app(str(app_id), ("uid", "Nickname"))
        drafts = []
        for account in ("a", "b"):
            draft = app.h_submit_prepare({"repo_url": "https://github.com/o/r"},
                "ip", (account, account))
            drafts.append((account, draft))
        barrier = threading.Barrier(2)

        def claim(item):
            account, draft = item
            barrier.wait(timeout=2)
            try:
                app.h_submit_confirm({"draft_token": draft["draft_token"],
                    "asset_name": "main-v2.hap", "category": "工具"}, (account, account))
                return 200
            except app.ApiError as e:
                return e.status
            finally:
                db.connect().close()
                del db._local.conn

        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(claim, drafts))
        self.assertEqual(sorted(outcomes), [200, 403])
        self.assertIn(db.publisher_account_id(app_id), ("a", "b"))

    def test_unlisting_cancels_pending_worker(self):
        app_id = self.confirm(self.prepare())["app"]["id"]
        app.h_remove_my_app(str(app_id), ("uid", "Nickname"))
        with patch.object(collector, "sync_app") as sync:
            self.assertFalse(submissions.process_one())
        sync.assert_not_called()
        self.assertEqual(self.task(app_id)["status"], "cancelled")

    def test_unlisting_during_scan_prevents_result_from_republishing(self):
        app_id = self.confirm(self.prepare())["app"]["id"]
        task = db.claim_catalog_task()
        app.h_remove_my_app(str(app_id), ("uid", "Nickname"))
        metadata = {"display_name": "Unexpected"}
        self.assertFalse(db.apply_catalog_snapshot("o/r", metadata, self.releases,
                                                   task["generation"])[2])
        self.assertEqual(db.get_app(app_id)["status"], "hidden")
        self.assertNotEqual(db.get_app(app_id)["display_name"], "Unexpected")

    def test_old_worker_cannot_overwrite_new_hap_selection(self):
        draft = self.prepare()
        app_id = self.confirm(draft)["app"]["id"]
        old_task = db.claim_catalog_task()
        new_draft = self.prepare()
        self.confirm(new_draft, "helper.hap", "影音")
        self.assertFalse(db.apply_catalog_snapshot("o/r", {"display_name": "Old"},
                          self.releases, old_task["generation"])[2])
        db.fail_catalog_task(app_id, old_task["generation"], "stale error")
        self.assertEqual(self.task(app_id)["status"], "pending")
        self.assertEqual(self.task(app_id)["last_error"], "")
        self.assertEqual(db.get_app_selection(app_id)["asset_name"], "helper.hap")

    def test_category_changed_during_scan_is_preserved(self):
        app_id = self.confirm(self.prepare())["app"]["id"]
        task = db.claim_catalog_task()
        db.configure_published_app(app_id, "uid", "游戏")
        db.apply_catalog_snapshot("o/r", {"category": "工具"}, self.releases, task["generation"])
        self.assertEqual(db.get_app(app_id)["category"], "游戏")

    def test_interrupted_task_recovers_after_service_restart(self):
        app_id = self.confirm(self.prepare())["app"]["id"]
        db.claim_catalog_task()
        self.assertEqual(self.task(app_id)["status"], "running")
        db.recover_catalog_tasks()
        self.assertEqual(self.task(app_id)["status"], "pending")
        self.assertIsNotNone(db.claim_catalog_task())
        self.assertIsNone(db.claim_catalog_task())

    def test_periodic_collection_skips_pending_tasks(self):
        app_id = self.confirm(self.prepare())["app"]["id"]
        self.assertNotIn(app_id, [r["id"] for r in db.apps_needing_sync()])

    def test_prepare_uses_exact_digest_metadata_cache_for_hidden_app(self):
        app_id = db.upsert_app("o/r", display_name="Actual App", status="hidden")
        releases = copy.deepcopy(self.releases)
        self.enrich(releases)
        db.replace_releases(app_id, releases)
        db.set_app_selection(app_id, "main-v2.hap", "com.test.main")
        draft = self.prepare()
        self.assertEqual(draft["choices"][0]["display_name"], "Actual App")
        self.assertEqual(draft["choices"][0]["bundle_name"], "com.test.main")
        self.releases[0]["assets"][0]["sha256"] = "d" * 64
        with submissions._lock:
            submissions._cache.clear()
        db.connect().execute("DELETE FROM submit_draft")
        db.connect().commit()
        self.assertEqual(self.prepare()["choices"][0]["bundle_name"], "")

    def test_discovery_cache_is_shared_but_draft_tokens_are_account_bound(self):
        first = self.prepare()
        second = app.h_submit_prepare({"repo_url": "https://github.com/O/R"},
                                      "shared-ip", ("other", "Other"))
        self.assertNotEqual(first["draft_token"], second["draft_token"])
        self.assertIsNone(db.get_submit_draft(second["draft_token"], "uid"))
        self.assertEqual(self.fetch_releases.call_count, 1)
        repeated = self.prepare()
        self.assertNotIn("snapshot", repeated)
        self.assertEqual(repeated["draft_token"], first["draft_token"])

    def test_discovery_calls_have_short_upstream_deadlines(self):
        self.prepare()
        self.assertEqual(self.fetch_meta.call_args.kwargs["timeout"], 5)
        self.assertEqual(self.fetch_releases.call_args.kwargs["timeout"], 5)

    def test_recent_hidden_listing_can_be_relisted_without_github(self):
        import time
        app_id = db.upsert_app("o/r", status="hidden", synced_at=int(time.time()))
        db.replace_releases(app_id, self.releases)
        self.assertTrue(self.prepare()["choices"])
        self.fetch_meta.assert_not_called()
        self.fetch_releases.assert_not_called()

    def test_known_repo_uses_recent_index_during_upstream_outage(self):
        import time
        app_id = db.upsert_app("o/r", synced_at=int(time.time()) - 600)
        db.replace_releases(app_id, self.releases)
        self.fetch_meta.side_effect = collector.CollectError("rate limited")
        self.assertTrue(self.prepare()["choices"])
        self.fetch_meta.assert_called_once()

    def test_unknown_or_very_old_repo_does_not_invent_hap_choices_on_outage(self):
        import time
        app_id = db.upsert_app("o/r", synced_at=int(time.time()) - 25000)
        db.replace_releases(app_id, self.releases)
        self.fetch_meta.side_effect = collector.CollectError("offline")
        with self.assertRaises(app.ApiError) as failure:
            self.prepare()
        self.assertEqual(failure.exception.status, 502)

    def test_legacy_prepared_token_still_confirms_without_hap_download(self):
        draft = self.prepare()
        stored = db.get_submit_draft(draft["draft_token"], "uid")
        old = json.loads(stored["prepared_json"])
        old.pop("snapshot")
        db.connect().execute("UPDATE submit_draft SET prepared_json=? WHERE token=?",
                             (json.dumps(old), draft["draft_token"]))
        db.connect().commit()
        with patch.object(collector, "enrich_assets_with_hap_metadata",
                          side_effect=AssertionError("foreground download")):
            self.assertEqual(self.confirm(draft)["status"], "ok")

    def test_publisher_change_cannot_mutate_listing_during_confirmation(self):
        draft = self.prepare()
        app_id = db.upsert_app("o/r", display_name="Other", category="游戏")
        db.set_publisher(app_id, "someone-else", "Other")
        with self.assertRaises(app.ApiError) as failure:
            self.confirm(draft)
        self.assertEqual(failure.exception.status, 403)
        self.assertEqual(db.get_app(app_id)["category"], "游戏")
        self.assertEqual(db.get_app(app_id)["display_name"], "Other")
        self.assertIsNone(db.connect().execute("SELECT * FROM catalog_task").fetchone())

    def test_latest_publication_selected_even_if_github_list_is_out_of_order(self):
        self.releases.reverse()
        self.assertEqual(self.prepare()["choices"][0]["tag"], "v2")

    def test_real_hap_is_only_parsed_by_worker(self):
        # Real zip parsing and icon decoding, only replacing the network transfer.
        pixels = io.BytesIO()
        Image.new("RGBA", (128, 128), "green").save(pixels, format="PNG")
        package = io.BytesIO()
        with zipfile.ZipFile(package, "w") as z:
            z.writestr("pack.info", json.dumps({"summary": {"app": {
                "bundleName": "com.test.real", "version": {"code": 200, "name": "2.0"}}}}))
            z.writestr("module.json", json.dumps({"app": {
                "bundleName": "com.test.real", "label": "Real App",
                "icon": "$media:app_icon", "versionCode": 200, "versionName": "2.0"}}))
            z.writestr("resources/base/media/app_icon.png", pixels.getvalue())
        blob = package.getvalue()
        import hashlib
        self.releases = [copy.deepcopy(self.releases[0])]
        self.releases[0]["assets"] = [self.releases[0]["assets"][0]]
        self.releases[0]["assets"][0]["sha256"] = hashlib.sha256(blob).hexdigest()
        self.releases[0]["assets"][0]["size"] = len(blob)

        def transfer(*args, **kwargs):
            handle, path = tempfile.mkstemp(dir=self.tmp.name, suffix=".hap")
            with os.fdopen(handle, "wb") as f:
                f.write(blob)
            return path

        with patch.object(collector, "_download_to_temp", side_effect=transfer) as download:
            app_id = self.confirm(self.prepare())["app"]["id"]
            download.assert_not_called()
            submissions.process_one()
            self.assertEqual(download.call_count, 1)
        self.assertEqual(db.get_app(app_id)["display_name"], "Real App")
        self.assertEqual(db.get_app(app_id)["latest_asset"]["version_code"], 200)
        self.assertIsNotNone(db.app_icon(app_id))
        self.assertFalse([n for n in os.listdir(self.tmp.name) if n.endswith(".hap")])


if __name__ == "__main__":
    unittest.main()
