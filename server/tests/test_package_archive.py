"""APP/ZIP validation, multi-selection and durable preparation regressions."""
import copy
import hashlib
import io
import json
import os
import tempfile
import threading
import unittest
import zipfile
from unittest.mock import patch
from server.hapstore import app, collector, db, submissions, package_archive as archive


def hap(bundle='com.example.app', module='entry', code=12):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('module.json', json.dumps({'app': {'bundleName': bundle, 'versionCode': code,
            'versionName': '1.2.0', 'label': 'Archive App'}, 'module': {'name': module,
            'type': 'entry' if module == 'entry' else 'feature',
            'mainElement': 'MainAbility' if module == 'entry' else ''}}))
    return buffer.getvalue()


def pack(entries):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in entries: z.writestr(name, data)
    return buffer.getvalue()


class PackageArchiveTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old = db.DB_PATH
        db.DB_PATH = self.temp.name + '/store.db'
        db._local = threading.local(); db._initialized = False; db.init_db()
        self.addCleanup(self.restore)
        app._rl.clear(); submissions._cache.clear(); submissions._inflight.clear()

    def restore(self):
        db.connect().close(); db.DB_PATH = self.old; db._local = threading.local(); db._initialized = False
        self.temp.cleanup()

    def download(self, data):
        def downloaded(*args, **kwargs):
            fd, path = tempfile.mkstemp(dir=self.temp.name); os.close(fd)
            with open(path, 'wb') as file: file.write(data)
            return path
        return patch.object(collector, '_download_to_temp', side_effect=downloaded)

    def asset(self, name, data):
        return {'name': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                'download_url': 'https://github.com/o/r/releases/download/v1/' + name}

    def snapshot(self, assets):
        return {'metadata': {'display_name': 'Repo', 'category': '工具', 'description': ''},
            'releases': [{'tag': 'v1', 'name': 'v1', 'published_at': '2026-10-01', 'assets': assets}]}

    def test_app_checks_all_modules_and_uses_entry_metadata(self):
        data = pack([('feature.hap', hap(module='feature')), ('entry.hap', hap())])
        with self.download(data):
            out = archive.scan_asset(self.asset('app.app', data))
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]['display_name'], 'Archive App')
        self.assertEqual(out[0]['bundle_name'], 'com.example.app')
        self.assertEqual(out[0]['_module_name'], 'entry')

    def test_mixed_app_modules_and_duplicate_module_names_are_rejected(self):
        for other in (hap(bundle='com.example.other'), hap(code=13), hap()):
            data = pack([('entry.hap', hap()), ('another.hap', other)])
            with self.download(data), self.assertRaises(collector.CollectError):
                archive.scan_asset(self.asset('bad.app', data))

    def test_zip_offers_only_valid_app_and_hap_with_bound_entry_selectors(self):
        data = pack([('dir/main.hap', hap()), ('nested.app', pack([('entry.hap', hap())])),
                     ('fake.hap', b'not a hap'), ('readme.txt', b'ignore')])
        with self.download(data):
            out = archive.scan_asset(self.asset('release.zip', data))
        self.assertEqual([a['name'] for a in out], ['release.zip / dir/main.hap', 'release.zip / nested.app'])
        self.assertTrue(out[0]['download_url'].endswith('#qingqi-package=dir%2Fmain.hap'))
        self.assertEqual(out[0]['sha256'], hashlib.sha256(data).hexdigest())
        with self.download(data):
            chosen = archive.scan_asset(out[1])
        self.assertEqual([a['name'] for a in chosen], [out[1]['name']])

    def test_zip_empty_fake_traversal_and_size_count_limits(self):
        fixtures = [pack([('notes.txt', b'no package')]), pack([('fake.hap', b'not a hap')]),
                    pack([('../escape.hap', hap())]), pack([(f'{i}.hap', hap()) for i in range(33)])]
        for data in fixtures:
            with self.download(data), self.assertRaises(collector.CollectError):
                archive.scan_asset(self.asset('bad.zip', data))

    def test_changed_upstream_digest_never_becomes_a_valid_choice(self):
        data = pack([('entry.hap', hap())]); asset = self.asset('app.app', data); asset['sha256'] = '0' * 64
        with self.download(data), self.assertRaisesRegex(collector.CollectError, '摘要'):
            archive.scan_asset(asset)

    def prepare(self, snapshot):
        with patch.object(submissions, 'prepared_snapshot', return_value=copy.deepcopy(snapshot)):
            return app.h_submit_prepare({'repo_url': 'https://github.com/o/r'}, 'ip', ('owner', 'Nickname'))

    def test_zip_preparation_is_durable_async_authenticated_and_confirm_is_blocked_until_ready(self):
        data = pack([('main.hap', hap()), ('other.hap', hap(bundle='com.example.other'))])
        snapshot = self.snapshot([self.asset('release.zip', data)])
        with patch.object(archive, 'scan_asset', side_effect=AssertionError('foreground scan')):
            draft = self.prepare(snapshot)
        self.assertEqual(draft['inspection_status'], 'pending')
        body = {'draft_token': draft['draft_token']}
        with self.assertRaises(app.ApiError): app.h_submit_status(body, ('other', 'Other'))
        with self.assertRaises(app.ApiError):
            app.h_submit_confirm(dict(body, asset_names=['release.zip'], category='工具'), ('owner', 'Nickname'))
        with self.download(data): self.assertTrue(submissions.process_prepare_one())
        checked = app.h_submit_status(body, ('owner', 'Nickname'))
        self.assertEqual(checked['inspection_status'], 'ready')
        self.assertEqual(len(checked['choices']), 2)
        result = app.h_submit_confirm(dict(body, asset_names=[a['name'] for a in checked['choices']], category='影音'), ('owner', 'Nickname'))
        self.assertEqual(len(db.list_releases(result['app']['id'])['items'][0]['assets']), 2)
        self.assertEqual(len(db.get_app_selection(result['app']['id'])['assets']), 2)

    def test_invalid_archive_cannot_be_confirmed_and_error_can_be_rechecked(self):
        data = pack([('fake.hap', b'bad')]); draft = self.prepare(self.snapshot([self.asset('bad.zip', data)]))
        with self.download(data): submissions.process_prepare_one()
        with self.assertRaises(app.ApiError) as failure:
            app.h_submit_status({'draft_token': draft['draft_token']}, ('owner', 'Nickname'))
        self.assertEqual(failure.exception.code, 'INVALID_PACKAGE_ARCHIVE')
        self.assertIsNone(db.recent_submit_draft('o/r', 'owner'))

    def test_multi_selection_survives_worker_and_periodic_collection(self):
        assets = [dict(self.asset('main.hap', b'a'), bundle_name='com.example.app'),
                  dict(self.asset('other.hap', b'b'), bundle_name='com.example.other'),
                  dict(self.asset('not-selected.hap', b'c'), bundle_name='com.example.third')]
        snapshot = self.snapshot(assets); draft = self.prepare(snapshot)
        body = dict(draft_token=draft['draft_token'], asset_names=['main.hap','other.hap'], category='工具')
        app_id = app.h_submit_confirm(body, ('owner','Nickname'))['app']['id']
        with patch.object(collector, 'enrich_assets_with_hap_metadata'):
            submissions.process_one()
        self.assertEqual([a['name'] for a in db.list_releases(app_id)['items'][0]['assets']], ['main.hap','other.hap'])
        newer = copy.deepcopy(snapshot); newer['releases'][0]['tag'] = 'v2'
        newer['releases'][0]['published_at'] = '2026-10-02'
        newer['releases'][0]['assets'][0]['name'] = 'main-v2.hap'
        newer['releases'][0]['assets'][1]['name'] = 'other-v2.hap'
        with patch.object(collector, 'enrich_assets_with_hap_metadata'):
            collector.sync_app('o/r', snapshot=newer)
        self.assertEqual([a['name'] for a in db.list_releases(app_id)['items'][0]['assets']], ['main-v2.hap','other-v2.hap'])
        self.assertEqual(db.get_app(app_id)['category'], '工具')
        self.assertEqual({a['bundle_name'] for a in db.get_app(app_id)['latest_assets']},
                         {'com.example.app', 'com.example.other'})
        with self.assertRaises(app.ApiError):
            app.h_submit_confirm(dict(body, asset_names=['main.hap','forged.hap']), ('owner','Nickname'))


    def test_unrelated_invalid_zip_does_not_hide_other_valid_release_choices(self):
        plain = self.asset('valid.hap', b'hap')
        snapshot = self.snapshot([self.asset('docs.zip', b'bad zip'), plain])
        with patch.object(archive, 'scan_asset', side_effect=collector.CollectError('no package')):
            checked = archive.inspect_snapshot(snapshot)
        self.assertEqual([a['name'] for a in checked['releases'][0]['assets']], ['valid.hap'])
