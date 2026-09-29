"""Category, HAP icon and verified user content regression tests."""

import io
import json
import os
import struct
import tempfile
import unittest
import zipfile
from unittest.mock import patch

from server.hapstore import app, auth, collector, db, transfer


class StoreFeaturesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_db = db.DB_PATH
        db.DB_PATH = os.path.join(self.tmp.name, "store.db")
        db._local = __import__("threading").local()
        db._initialized = False
        db.init_db()

    def tearDown(self):
        db.connect().close()
        db.DB_PATH = self.old_db
        db._local = __import__("threading").local()
        db._initialized = False
        self.tmp.cleanup()

    def test_category_uses_topics_and_has_neutral_fallback(self):
        self.assertEqual(collector.classify_repo(["music-player", "harmonyos"]), "影音")
        self.assertEqual(collector.classify_repo(["harmonyos"]), "其他")

    def test_hap_icon_is_extracted_from_named_media(self):
        path = os.path.join(self.tmp.name, "app.hap")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("resources/base/media/app_icon.png", b"\x89PNG\r\n\x1a\n" + b"x" * 120)
            z.writestr("resources/base/media/screenshot.png", b"\x89PNG\r\n\x1a\n" + b"y" * 120)
        icon = collector.extract_hap_icon(path)
        self.assertEqual(icon[0], "image/png")
        self.assertEqual(icon[1][-1:], b"x")

    def test_hap_display_name_uses_label_id_in_compiled_resources(self):
        name = "轻启·安装器".encode("utf-8")
        index = bytearray(156)
        index[:9] = b"RestoolV2"
        struct.pack_into("<4sIII", index, 140, b"IDSS", 0, 1, 1)
        index.extend(struct.pack("<III", 9, 0, 1))
        name_ref = b"app_name"
        index.extend(struct.pack("<III", 0x01000000, 0, len(name_ref)))
        index.extend(name_ref)
        entry_offset = len(index)
        index.extend(struct.pack("<IIIII", 0x01000000, 20, 1, 0, 0))
        value_offset = len(index)
        index.extend(struct.pack("<H", len(name)) + name)
        struct.pack_into("<I", index, 172, entry_offset)
        struct.pack_into("<I", index, entry_offset + 16, value_offset)
        struct.pack_into("<III", index, 128, len(index), 0, 140)

        path = os.path.join(self.tmp.name, "named.hap")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("module.json", json.dumps({"app": {
                "bundleName": "com.example.app", "label": "$string:app_name",
                "labelId": 0x01000000}}))
            z.writestr("resources.index", index)
        self.assertEqual(collector.parse_hap_metadata(path)["display_name"], "轻启·安装器")
        self.assertEqual(collector._resource_string(b"broken", 0x01000000), "")

    def test_seed_export_contains_hap_icon(self):
        app_id = db.upsert_app("owner/repo")
        db.put_app_icon(app_id, "image/png", b"\x89PNG" + b"x" * 120)
        payload = transfer.export_all()
        self.assertEqual(payload["export_version"], 2)
        self.assertEqual(payload["apps"][0]["icon"]["mime"], "image/png")

    def test_publisher_cannot_be_replaced_by_another_submitter(self):
        app_id = db.upsert_app("owner/repo")
        db.set_publisher(app_id, "uid-a", "Alice")
        db.set_publisher(app_id, "uid-b", "Bob")
        self.assertEqual(db.get_app(app_id)["publisher_name"], "Alice")

    def test_repo_ownership_state_drives_duplicate_rejection(self):
        app_id = db.upsert_app("owner/repo", display_name="Actual App")
        # 采集进来但没人上架的仓库仍按首次上架处理
        self.assertEqual(app._repo_owner_state("owner/repo", "uid-a")["state"], "new")
        db.set_publisher(app_id, "uid-a", "Alice")
        self.assertEqual(app._repo_owner_state("owner/repo", "uid-a")["state"], "mine")
        self.assertEqual(app._repo_owner_state("owner/repo", "uid-b")["state"], "other")
        self.assertEqual(app._repo_owner_state("nobody/else", "uid-a")["state"], "new")
        # 别人的仓库直接拒绝，不再走一次 GitHub 采集
        app._reject_foreign_repo("owner/repo", "uid-a")
        with self.assertRaises(app.ApiError) as denied:
            app._reject_foreign_repo("owner/repo", "uid-b")
        self.assertEqual(denied.exception.status, 403)

    def test_only_publisher_can_remove_public_listing(self):
        app_id = db.upsert_app("owner/repo", display_name="Actual App")
        db.set_publisher(app_id, "uid-a", "Alice")
        self.assertEqual(len(app.h_my_apps(("uid-a", "Alice"))["items"]), 1)
        self.assertEqual(app.h_my_apps(("uid-b", "Bob"))["items"], [])
        with self.assertRaises(app.ApiError) as denied:
            app.h_remove_my_app(str(app_id), ("uid-b", "Bob"))
        self.assertEqual(denied.exception.status, 403)
        self.assertEqual(db.get_app(app_id)["status"], "published")
        self.assertTrue(app.h_remove_my_app(str(app_id), ("uid-a", "Alice"))["removed"])
        self.assertEqual(db.list_apps()["items"], [])
        self.assertEqual(app.h_my_apps(("uid-a", "Alice"))["items"], [])
        with self.assertRaises(app.ApiError) as removed:
            app.h_app_detail(str(app_id), {})
        self.assertEqual(removed.exception.status, 404)
        db.upsert_app("owner/repo", status="published")
        self.assertEqual(db.get_app(app_id)["display_name"], "Actual App")

    def test_same_account_can_post_multiple_reviews_and_ignores_body_name(self):
        app_id = db.upsert_app("owner/repo")
        app.h_put_review(str(app_id), {"stars": 3, "body": "Good", "display_name": "Spoof"},
                         ("uid-a", "Alice"))
        app.h_put_review(str(app_id), {"stars": 5, "body": "Better"}, ("uid-a", "Alice"))
        reviews = db.list_reviews(app_id)
        self.assertEqual(reviews["summary"], {"count": 2, "average": 4.0})
        self.assertEqual(reviews["items"][0]["display_name"], "Alice")
        self.assertEqual({item["body"] for item in reviews["items"]}, {"Good", "Better"})
        self.assertEqual(len({item["id"] for item in reviews["items"]}), 2)

    def test_review_pages_expose_total_and_do_not_repeat_items(self):
        app_id = db.upsert_app("owner/repo")
        for index in range(5):
            db.put_review(app_id, f"uid-{index}", f"User {index}", 5, f"Body {index}")

        first = app.h_reviews(str(app_id), {"page": ["1"], "page_size": ["2"]})
        second = app.h_reviews(str(app_id), {"page": ["2"], "page_size": ["2"]})
        last = app.h_reviews(str(app_id), {"page": ["3"], "page_size": ["2"]})

        # total is the server-side count, not the length of the current page
        self.assertEqual([first["total"], second["total"], last["total"]], [5, 5, 5])
        self.assertEqual([first["page"], second["page"], last["page"]], [1, 2, 3])
        self.assertEqual([len(first["items"]), len(second["items"]), len(last["items"])], [2, 2, 1])
        seen = [item["id"] for page in (first, second, last) for item in page["items"]]
        self.assertEqual(len(set(seen)), 5)

    def test_review_page_size_is_capped_like_the_other_listings(self):
        app_id = db.upsert_app("owner/repo")
        for index in range(3):
            db.put_review(app_id, f"uid-{index}", f"User {index}", 5, f"Body {index}")
        page = app.h_reviews(str(app_id), {"page_size": ["500"]})
        self.assertEqual(page["page_size"], 50)
        self.assertEqual(page["total"], 3)

    def test_verified_avatar_appears_on_all_existing_account_reviews(self):
        app_id = db.upsert_app("owner/repo")
        db.put_review(app_id, "uid-a", "Alice", 4, "First")
        db.put_review(app_id, "uid-a", "Alice", 5, "Second")
        db.set_account_avatar("uid-a", "https://example.com/avatar.png")
        self.assertEqual([r["avatar_url"] for r in db.list_reviews(app_id)["items"]],
                         ["https://example.com/avatar.png"] * 2)

    def test_temporary_profile_failure_keeps_verified_public_nickname(self):
        app_id = db.upsert_app("owner/repo")
        db.set_publisher(app_id, "uid-a", "PublicName")
        db.put_review(app_id, "uid-a", "PublicName", 5, "Good")
        db.update_account_display_name("uid-a", "uid-a")
        self.assertEqual(db.get_app(app_id)["publisher_name"], "PublicName")
        self.assertEqual(db.list_reviews(app_id)["items"][0]["display_name"],
                         "PublicName")
        db.update_account_display_name("uid-a", "NewPublicName")
        self.assertEqual(db.get_app(app_id)["publisher_name"], "NewPublicName")

    def test_old_unique_review_table_migrates_without_losing_comments(self):
        conn = db.connect()
        conn.execute("DROP TABLE review")
        conn.execute("""CREATE TABLE review (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id INTEGER NOT NULL REFERENCES app(id) ON DELETE CASCADE,
            account_id TEXT NOT NULL, display_name TEXT NOT NULL,
            stars INTEGER NOT NULL, body TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            UNIQUE(app_id, account_id))""")
        app_id = db.upsert_app("owner/repo")
        conn.execute("""INSERT INTO review(app_id,account_id,display_name,stars,body,
                     created_at,updated_at) VALUES (?,?,?,?,?,?,?)""",
                     (app_id, "uid-a", "Alice", 4, "Old", 1, 1))
        conn.commit()
        db._initialized = False
        db.init_db()
        db.put_review(app_id, "uid-a", "Alice", 5, "New")
        self.assertEqual(db.review_summary(app_id), {"count": 2, "average": 4.5})

    def test_submit_requires_prepare_then_selected_hap_and_category(self):
        releases = [{"tag": "v1", "name": "v1", "body": "", "published_at": "2026-01-01",
                     "prerelease": False, "html_url": "", "etag": "1", "assets": [
                         {"name": "main.hap", "size": 100, "sha256": "a" * 64,
                          "download_url": "https://github.com/main.hap",
                          "bundle_name": "com.test.main"},
                         {"name": "helper.hap", "size": 50, "sha256": "b" * 64,
                          "download_url": "https://github.com/helper.hap",
                          "bundle_name": "com.test.helper",
                          "display_name": "Helper App"}]}]
        metadata = {"display_name": "Test", "description": "desc", "category": "工具"}
        with patch.object(collector, "fetch_app_metadata", return_value=metadata), \
             patch.object(collector, "fetch_releases", return_value=releases), \
             patch.object(collector, "enrich_assets_with_hap_metadata"), \
             patch.object(collector, "sync_app", side_effect=lambda *args, **kwargs:
                          {"app_id": db.upsert_app("owner/repo"), "hap_assets": 1}):
            draft = app.h_submit_prepare({"repo_url": "https://github.com/owner/repo"},
                                         "127.0.0.1", ("uid-a", "Alice"))
            self.assertEqual(len(draft["choices"]), 2)
            self.assertEqual(draft["choices"][1]["display_name"], "Helper App")
            self.assertIsNone(db.connect().execute("SELECT id FROM app").fetchone())
            with self.assertRaises(app.ApiError):
                app.h_submit_confirm({"draft_token": draft["draft_token"],
                                      "asset_name": "other.hap", "category": "工具"},
                                     ("uid-a", "Alice"))
            with self.assertRaises(app.ApiError):
                app.h_submit_confirm({"draft_token": draft["draft_token"],
                                      "asset_name": "main.hap", "category": "bad"},
                                     ("uid-a", "Alice"))
            with self.assertRaises(app.ApiError):
                app.h_submit_confirm({"draft_token": draft["draft_token"],
                                      "asset_name": "main.hap", "category": "工具"},
                                     ("uid-b", "Bob"))
            result = app.h_submit_confirm({"draft_token": draft["draft_token"],
                                           "asset_name": "helper.hap", "category": "影音"},
                                          ("uid-a", "Alice"))
            self.assertEqual(result["app"]["category"], "影音")
            self.assertEqual(result["app"]["display_name"], "Helper App")
            self.assertEqual(result["app"]["publisher_name"], "Alice")
            self.assertEqual(db.get_app_selection(result["app"]["id"])["asset_name"],
                             "helper.hap")

    def test_submit_rejects_stale_selected_hap_even_when_bundle_matches(self):
        releases = [{"tag": "v2", "assets": [
            {"name": "replacement.hap", "bundle_name": "com.test.app"}]}]
        with patch.object(collector, "fetch_app_metadata", return_value={}), \
             patch.object(collector, "fetch_releases", return_value=releases), \
             patch.object(collector, "enrich_assets_with_hap_metadata"):
            with self.assertRaises(collector.CollectError):
                collector.sync_app("owner/repo", selection={
                    "tag": "v2", "asset_name": "selected.hap",
                    "bundle_name": "com.test.app"})
        self.assertIsNone(db.connect().execute("SELECT id FROM app").fetchone())

    def test_identity_is_read_from_remote_validation_only(self):
        token = "test.jwt.token"
        response = io.BytesIO(json.dumps({"userInfo": {"userId": "uid", "nickName": "Alice"}}).encode())
        response.status = 200
        with patch.object(auth.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            # DevEco may return a masked nickname. Without a GOpen access
            # token, use the full account ID rather than that field.
            self.assertEqual(auth.verify(token), ("uid", "uid"))
        with self.assertRaises(auth.InvalidIdentity):
            auth.verify("")


if __name__ == "__main__":
    unittest.main()
