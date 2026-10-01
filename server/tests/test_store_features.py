"""Category, HAP icon and verified user content regression tests."""

import io
import json
import os
import struct
import tempfile
import time
import unittest
import zipfile
from unittest.mock import patch

from PIL import Image

from server.hapstore import submissions
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

    def test_every_keyword_category_is_submittable(self):
        """关键词表产出的分类必须都在上架白名单里。

        否则自动识别给出的分类在提交时会被 INVALID_CATEGORY 挡下 —— 用户看到
        一个「建议分类」却选不了，只能自己改。
        """
        allowed = set(app.SUBMIT_CATEGORIES)
        for category, _ in collector._CATEGORY_KEYWORDS:
            self.assertIn(category, allowed)

    def test_categories_have_no_duplicates_and_keep_legacy_values(self):
        self.assertEqual(len(app.SUBMIT_CATEGORIES), len(set(app.SUBMIT_CATEGORIES)))
        # 线上已有记录的取值必须仍然可提交，否则老应用改分类会被拒。
        for legacy in ("工具", "开发工具", "效率", "影音", "游戏",
                       "教育", "生活", "系统工具", "其他"):
            self.assertIn(legacy, app.SUBMIT_CATEGORIES)

    def test_new_categories_are_reachable_by_heuristic(self):
        cases = {
            "社交通讯": ["chat"],
            "摄影录像": ["camera"],
            "出行导航": ["navigation"],
            "财务": ["accounting"],
            "安全隐私": ["vpn"],
            "儿童": ["kids"],
            "办公": ["spreadsheet"],
            "学习": ["dictionary"],
        }
        for expected, topics in cases.items():
            self.assertEqual(collector.classify_repo(topics), expected)

    # ── 版本列表必须跟着上游删 ──────────────────────────────────
    #
    # 上游删掉 Release 或 tag 之后，采集结果里就没有它了。若 replace_releases
    # 只做 upsert，那条记录会永远留在库里，客户端刷新多少次都还能看到 ——
    # 用户在 GitHub 删掉的版本，商店里仍然列着。

    @staticmethod
    def _release(tag, assets=("a.hap",)):
        return {"tag": tag, "name": tag, "body": "", "published_at": "2026-01-01",
                "prerelease": False, "html_url": "https://example.org/" + tag,
                "etag": "",
                "assets": [{"name": n, "size": 1, "sha256": "x" * 64,
                            "download_url": "https://example.org/" + n} for n in assets]}

    def _tags(self, app_id):
        return sorted(row["tag"]
                      for row in db.list_releases(app_id, page_size=50)["items"])

    def test_release_removed_upstream_disappears(self):
        app = db.upsert_app("owner/repo")
        db.replace_releases(app, [self._release("v1"), self._release("v2"),
                                  self._release("v3")])
        self.assertEqual(self._tags(app), ["v1", "v2", "v3"])
        db.replace_releases(app, [self._release("v1"), self._release("v3")])
        self.assertEqual(self._tags(app), ["v1", "v3"])

    def test_prerelease_is_manual_only_and_never_becomes_latest_update(self):
        app_id = db.upsert_app("owner/repo")
        stable = self._release("v1")
        stable["assets"][0].update(bundle_name="com.example.app", version_code=1)
        preview = self._release("v2-preview")
        preview["prerelease"] = True
        preview["published_at"] = "2026-02-01"
        preview["assets"][0].update(bundle_name="com.example.app", version_code=2)
        db.replace_releases(app_id, [stable, preview])
        db.connect().execute("UPDATE app SET status='published' WHERE id=?", (app_id,))
        db.connect().commit()
        catalog = db.get_app(app_id)
        self.assertEqual(catalog["latest"]["tag"], "v1")
        self.assertEqual(catalog["latest_asset"]["version_code"], 1)
        self.assertEqual(catalog["releases_count"], 1)
        self.assertEqual(app.h_app_releases(str(app_id), {})["total"], 1)
        manual = app.h_app_releases(str(app_id), {"prerelease": ["1"]})
        self.assertEqual(manual["total"], 2)
        self.assertTrue(any(row["prerelease"] for row in manual["items"]))

    def test_removed_release_takes_its_assets_with_it(self):
        app = db.upsert_app("owner/repo")
        db.replace_releases(app, [self._release("v1", ("a.hap", "b.hap"))])
        db.replace_releases(app, [self._release("v2")])
        row = db.connect().execute("SELECT COUNT(*) AS n FROM asset").fetchone()
        self.assertEqual(row["n"], 1)

    def test_empty_collection_does_not_wipe_version_history(self):
        """抓取失败或限流时列表可能是空的，一次抖动不该清空历史。"""
        app = db.upsert_app("owner/repo")
        db.replace_releases(app, [self._release("v1"), self._release("v2")])
        db.replace_releases(app, [])
        self.assertEqual(self._tags(app), ["v1", "v2"])

    def test_pruning_does_not_touch_other_apps(self):
        other = db.upsert_app("owner/other")
        db.replace_releases(other, [self._release("keep")])
        app = db.upsert_app("owner/repo")
        db.replace_releases(app, [self._release("v1")])
        db.replace_releases(app, [self._release("v2")])
        self.assertEqual(self._tags(other), ["keep"])

    # ── 下拉刷新的批量重采 ──────────────────────────────────────
    #
    # `GET /apps` 读缓存目录，`latest_asset` 要等采集周期才更新，所以下拉刷新原本
    # 看不到刚发布的版本。这个接口把单应用的即时重采批量化。

    def _stale_app(self, repo, synced_at=0):
        app_id = db.upsert_app(repo, status="published")
        db.connect().execute("UPDATE app SET synced_at=? WHERE id=?", (synced_at, app_id))
        db.connect().commit()
        return app_id

    def test_batch_refresh_collects_only_stale_apps(self):
        fresh = self._stale_app("owner/fresh", synced_at=int(time.time()))
        stale = self._stale_app("owner/stale", synced_at=0)
        collected: list[str] = []

        def sync(repo, token=""):
            collected.append(repo)
            return {"releases": 1}

        with patch.object(app.collector, "sync_app", side_effect=sync):
            out = app.h_refresh_stale_apps("10.0.0.1", 4, 12.0)
            self.assertEqual(collected, [])
            submissions.process_refresh_one()
        self.assertEqual(collected, ["owner/stale"])
        self.assertEqual([r["app_id"] for r in out["queued"]], [stale])
        del fresh

    def test_batch_refresh_survives_one_broken_repo(self):
        """单个仓库不可达不该让整次刷新失败 —— 下拉刷新宁可用旧数据。"""
        self._stale_app("owner/broken", synced_at=0)
        self._stale_app("owner/ok", synced_at=0)

        def sync(repo, token=""):
            if repo == "owner/broken":
                raise app.collector.CollectError("boom")
            return {"releases": 1}

        with patch.object(app.collector, "sync_app", side_effect=sync):
            out = app.h_refresh_stale_apps("10.0.0.2", 4, 12.0)
            self.assertEqual(len(out['queued']), 2)
            submissions.process_refresh_one()
            submissions.process_refresh_one()
        tasks = db.connect().execute('SELECT a.repo_full_name,t.status FROM refresh_task t JOIN app a ON a.id=t.app_id').fetchall()
        self.assertEqual(dict((r[0],r[1]) for r in tasks), {'owner/ok': 'done', 'owner/broken': 'pending'})

    def test_stale_published_apps_exposes_the_same_fields_as_get_app(self):
        """字段名必须与 `get_app` 一致。

        这条是为了防一个真实踩过的坑：直接返回原始 SQLite Row 时字段叫
        `repo_full_name`，而接口层按 `repo` 取值 → 拿到空串 → 循环里什么都不做，
        接口静默返回「考虑了 N 个应用、刷新 0 个」。上面几个用例 mock 掉了
        sync_app，不会经过这个字段，所以需要单独盯住它。
        """
        app_id = self._stale_app("owner/fields", synced_at=0)
        rows = db.stale_published_apps(max_age_seconds=300, limit=4)
        self.assertEqual([r["id"] for r in rows], [app_id])
        self.assertEqual(rows[0]["repo"], "owner/fields")
        self.assertEqual(rows[0]["status"], "published")

    def test_batch_refresh_collects_the_repo_name_it_reads(self):
        """端到端：不 mock 采集，只替换成记录调用，验证真的拿到了仓库名。"""
        self._stale_app("owner/e2e", synced_at=0)
        collected: list[str] = []

        def sync(repo, token=""):
            collected.append(repo)
            return {"releases": 0}

        with patch.object(app.collector, "sync_app", side_effect=sync):
            app.h_refresh_stale_apps("10.0.0.9", 4, 12.0)
            self.assertEqual(collected, [])
            submissions.process_refresh_one()
        self.assertEqual(collected, ["owner/e2e"])

    def test_batch_refresh_is_rate_limited(self):
        limit, _window = app.RATE_REFRESH_STALE
        with patch.object(app.collector, "sync_app", return_value={"releases": 0}):
            for _ in range(limit):
                app.h_refresh_stale_apps("10.0.0.3", 4, 12.0)
            with self.assertRaises(app.ApiError) as ctx:
                app.h_refresh_stale_apps("10.0.0.3", 4, 12.0)
        self.assertEqual(ctx.exception.status, 429)

    # ── 采集新鲜度开关 ──────────────────────────────────────────
    #
    # 后台循环按 HAPSTORE_SYNC_INTERVAL 唤醒，但每次只采 apps_needing_sync() 挑出来
    # 的应用。那个函数原来硬编码 6 小时，于是「每 30 分钟醒一次、却只采超过 6 小时
    # 没采的」—— 改 SYNC_INTERVAL 完全没有效果。这几条盯住那个阈值真的接上了。

    def test_sync_max_age_defaults_to_one_hour(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("HAPSTORE_SYNC_MAX_AGE", None)
            self.assertEqual(collector.sync_max_age_seconds(), 3600)

    def test_sync_max_age_reads_the_environment(self):
        with patch.dict(os.environ, {"HAPSTORE_SYNC_MAX_AGE": "600"}):
            self.assertEqual(collector.sync_max_age_seconds(), 600)

    def test_sync_max_age_ignores_invalid_values(self):
        for bad in ("abc", "0", "-5", ""):
            with patch.dict(os.environ, {"HAPSTORE_SYNC_MAX_AGE": bad}):
                self.assertEqual(collector.sync_max_age_seconds(), 3600, bad)

    def test_sync_all_passes_the_configured_threshold(self):
        """阈值必须真的传到查询里 —— 只定义不接线等于没改。"""
        seen: list[int] = []
        real = db.apps_needing_sync

        def spy(limit=50, max_age_seconds=6 * 3600):
            seen.append(max_age_seconds)
            return real(limit=limit, max_age_seconds=max_age_seconds)

        with patch.dict(os.environ, {"HAPSTORE_SYNC_MAX_AGE": "120"}):
            with patch.object(app.collector.db, "apps_needing_sync", side_effect=spy):
                collector.sync_all(limit=1)
        self.assertEqual(seen, [120])

    def test_sync_all_picks_apps_older_than_the_threshold(self):
        """端到端：刚采过的不重复采，超过阈值的才采。"""
        fresh = self._stale_app("owner/fresh", synced_at=int(time.time()))
        stale = self._stale_app("owner/stale", synced_at=int(time.time()) - 7200)
        collected: list[str] = []

        def sync(repo, token="", progress=None):
            collected.append(repo)
            return {"releases": 0}

        with patch.dict(os.environ, {"HAPSTORE_SYNC_MAX_AGE": "600"}):
            with patch.object(collector, "sync_app", side_effect=sync):
                collector.sync_all(limit=10)
        self.assertEqual(collected, ["owner/stale"])
        del fresh, stale

    @staticmethod
    def _png(color, size=(64, 64)):
        output = io.BytesIO()
        Image.new("RGBA", size, color).save(output, format="PNG")
        return output.getvalue()

    def test_hap_icon_follows_manifest_reference_instead_of_filename(self):
        path = os.path.join(self.tmp.name, "app.hap")
        actual = self._png((12, 80, 140, 255))
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("module.json", json.dumps({"app": {"icon": "$media:brand"}}))
            z.writestr("resources/base/media/app_icon.png", self._png((255, 0, 0, 255)))
            z.writestr("resources/base/media/brand.png", actual)
        icon = collector.extract_hap_icon(path)
        self.assertEqual(icon[0], "image/png")
        self.assertEqual(icon[1], actual)

    def test_hap_icon_prefers_launcher_ability_over_app_template_icon(self):
        # Kazumi's app.icon points to a stock AppScope placeholder, while the
        # launcher ability's layered_image is the icon shown on the device.
        path = os.path.join(self.tmp.name, "launcher.hap")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("module.json", json.dumps({
                "app": {"icon": "$media:app_icon"},
                "module": {"mainElement": "EntryAbility", "abilities": [{
                    "name": "EntryAbility", "icon": "$media:layered_image",
                    "skills": [{"entities": ["entity.system.home"]}]
                }]}
            }))
            z.writestr("resources/base/media/app_icon.png", self._png((0, 90, 255, 255)))
            z.writestr("resources/base/media/layered_image.json", json.dumps({
                "layered-image": {"background": "$media:background",
                                  "foreground": "$media:foreground"}}))
            z.writestr("resources/base/media/background.png", self._png((0, 0, 0, 255)))
            z.writestr("resources/base/media/foreground.png", self._png((255, 100, 0, 255)))
        icon = collector.extract_hap_icon(path)
        self.assertIsNotNone(icon)
        self.assertEqual(Image.open(io.BytesIO(icon[1])).getpixel((20, 20)), (255, 100, 0, 255))

    def test_layered_icon_uses_resource_ids_and_composites_layers(self):
        # Real HarmonyOS HAPs point iconId at layered_image.json; that file
        # refers to foreground/background by numeric resource ID. A 1×1
        # startIcon.png is an unrelated launch placeholder.
        index = bytearray(156)
        index[:9] = b"RestoolV2"
        struct.pack_into("<4sIII", index, 140, b"IDSS", 0, 1, 1)
        index.extend(struct.pack("<III", 9, 0, 3))
        for rid, leaf in [(0x01000001, "background.png"),
                          (0x01000002, "foreground.png"),
                          (0x01000003, "layered_image.json")]:
            name = leaf.encode()
            index.extend(struct.pack("<III", rid, 0, len(name)))
            index.extend(name)
        pos = 168
        for rid, leaf in [(0x01000001, "background.png"),
                          (0x01000002, "foreground.png"),
                          (0x01000003, "layered_image.json")]:
            struct.pack_into("<I", index, pos + 4, len(index))
            pos += 12 + len(leaf)
            entry_offset = len(index)
            index.extend(struct.pack("<IIIII", rid, 20, 1, 0, 0))
            value = ("entry/resources/base/media/" + leaf).encode()
            value_offset = len(index)
            index.extend(struct.pack("<H", len(value)) + value)
            struct.pack_into("<I", index, entry_offset + 16, value_offset)
        struct.pack_into("<III", index, 128, len(index), 0, 140)
        path = os.path.join(self.tmp.name, "layered.hap")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("module.json", json.dumps({"app": {
                "icon": "$media:layered_image", "iconId": 0x01000003}}))
            z.writestr("resources.index", index)
            z.writestr("resources/base/media/layered_image.json", json.dumps({
                "layered-image": {"background": "$media:16777217",
                                  "foreground": "$media:16777218"}}))
            z.writestr("resources/base/media/background.png", self._png((0, 0, 255, 255)))
            z.writestr("resources/base/media/foreground.png", self._png((255, 0, 0, 128)))
            z.writestr("resources/base/media/startIcon.png", self._png((0, 0, 0, 0), (1, 1)))
        icon = collector.extract_hap_icon(path)
        self.assertIsNotNone(icon)
        self.assertEqual(icon[0], "image/png")
        pixel = Image.open(io.BytesIO(icon[1])).getpixel((20, 20))
        self.assertEqual(pixel, (128, 0, 127, 255))

    def test_layered_icon_supports_restool_6_resource_index(self):
        # ClashBox 1.7.4 uses the newer "Restool 6.0.0.00" index layout.
        paths = [(0x01000001, "background.png"),
                 (0x01000002, "foreground.png"),
                 (0x01000003, "layered_image.json")]
        index = bytearray(136)
        index[:16] = b"Restool 6.0.0.00"
        index.extend(struct.pack("<4sII", b"KEYS", 148, 0))
        index.extend(struct.pack("<4sI", b"IDSS", len(paths)))
        pairs_at = len(index)
        index.extend(b"\0" * (8 * len(paths)))
        for n, (rid, leaf) in enumerate(paths):
            offset = len(index)
            value = ("entry/resources/base/media/" + leaf).encode() + b"\0"
            index.extend(struct.pack("<IIIH", 14 + len(value), 19, rid, len(value)))
            index.extend(value)
            struct.pack_into("<II", index, pairs_at + 8 * n, rid, offset)
        struct.pack_into("<II", index, 128, len(index), 1)
        path = os.path.join(self.tmp.name, "restool6.hap")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("module.json", json.dumps({"app": {
                "icon": "$media:layered_image", "iconId": 0x01000003}}))
            z.writestr("resources.index", index)
            z.writestr("resources/base/media/layered_image.json", json.dumps({
                "layered-image": {"background": "$media:16777217",
                                  "foreground": "$media:16777218"}}))
            z.writestr("resources/base/media/background.png", self._png((0, 255, 0, 255)))
            z.writestr("resources/base/media/foreground.png", self._png((255, 0, 0, 128)))
        icon = collector.extract_hap_icon(path)
        self.assertIsNotNone(icon)
        self.assertEqual(Image.open(io.BytesIO(icon[1])).getpixel((20, 20)),
                         (128, 127, 0, 255))

    def test_app_icon_revision_changes_when_image_is_replaced(self):
        app_id = db.upsert_app("owner/repo", icon_url="https://github.com/owner.png")
        self.assertEqual(db.get_app(app_id)["icon_url"], "")
        db.put_app_icon(app_id, "image/png", self._png((0, 0, 0, 255)))
        old = db.get_app(app_id)["icon_rev"]
        db.put_app_icon(app_id, "image/png", self._png((255, 255, 255, 255)))
        self.assertNotEqual(db.get_app(app_id)["icon_rev"], old)
        db.delete_app_icon(app_id)
        self.assertEqual(db.get_app(app_id)["icon_url"], "")

    def test_failed_new_icon_scan_keeps_previous_verified_icon(self):
        app_id = db.upsert_app("owner/repo")
        old = self._png((30, 50, 70, 255))
        db.put_app_icon(app_id, "image/png", old)
        release = self._release("v2")
        release["assets"][0]["_icon_checked"] = True
        with patch.object(collector, "fetch_app_metadata", return_value={"category": "工具"}), \
             patch.object(collector, "fetch_releases", return_value=[release]), \
             patch.object(collector, "enrich_assets_with_hap_metadata"):
            collector.sync_app("owner/repo")
        self.assertEqual(db.app_icon(app_id), ("image/png", old))

    def test_temporary_hap_download_failure_preserves_verified_asset_metadata(self):
        app_id = db.upsert_app("owner/repo")
        old = {"tag": "v1", "published_at": "2026-09-30T00:00:00Z",
               "assets": [{"name": "app.hap", "sha256": "a" * 64,
                           "download_url": "https://github.com/owner/repo/app.hap",
                           "bundle_name": "com.example.app", "version_code": 42,
                           "version_name": "1.0", "min_api": 24}]}
        db.replace_releases(app_id, [old])
        db.set_app_selection(app_id, "app.hap", "com.example.app")
        fetched = {"tag": old["tag"], "published_at": old["published_at"],
                   "assets": [{"name": "app.hap", "sha256": "a" * 64,
                               "download_url": old["assets"][0]["download_url"]}]}
        with patch.object(collector, "fetch_app_metadata", return_value={"icon_url": ""}), \
             patch.object(collector, "fetch_releases", return_value=[fetched]):
            collector.sync_app("owner/repo", with_metadata=False)
        latest = db.get_app(app_id)["latest_asset"]
        self.assertEqual(latest["bundle_name"], "com.example.app")
        self.assertEqual(latest["version_code"], 42)

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

    def test_publisher_can_configure_category_and_collection_preserves_it(self):
        app_id = db.upsert_app("owner/repo", category="工具", display_name="App")
        db.set_publisher(app_id, "uid-a", "Alice")
        with self.assertRaises(app.ApiError) as denied:
            app.h_configure_my_app(str(app_id), {"category": "影音"}, ("uid-b", "Bob"))
        self.assertEqual(denied.exception.status, 403)
        for invalid in ("bad", None, ["工具"]):
            with self.assertRaises(app.ApiError) as invalid_error:
                app.h_configure_my_app(str(app_id), {"category": invalid}, ("uid-a", "Alice"))
            self.assertEqual(invalid_error.exception.status, 400)
        result = app.h_configure_my_app(str(app_id), {"category": "影音"}, ("uid-a", "Alice"))
        self.assertEqual(result["app"]["category"], "影音")
        with patch.object(collector, "fetch_app_metadata", return_value={"category": "工具"}), \
             patch.object(collector, "fetch_releases", return_value=[]):
            collector.sync_app("owner/repo", with_metadata=False)
        self.assertEqual(db.get_app(app_id)["category"], "影音")
        app.h_remove_my_app(str(app_id), ("uid-a", "Alice"))
        with self.assertRaises(app.ApiError) as hidden:
            app.h_configure_my_app(str(app_id), {"category": "工具"}, ("uid-a", "Alice"))
        self.assertEqual(hidden.exception.status, 404)

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
