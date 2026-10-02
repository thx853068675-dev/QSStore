"""Release channel classification and bounded metadata collection."""
import unittest
import hashlib
import json
import os
import tempfile
import zipfile
from unittest.mock import patch

from server.hapstore import collector


def release(tag, name='', assets=('app.hap',), preview=False):
    return {'tag_name': tag, 'name': name, 'prerelease': preview,
            'published_at': '2026-01-01',
            'assets': [{'name': a, 'browser_download_url': 'https://github.com/o/r/' + a}
                       for a in assets]}


class PreviewCollectionTest(unittest.TestCase):
    def test_only_github_prerelease_flag_defines_the_channel(self):
        rows = [release('Beta-V1.0.0.2'), release('v1', 'Beta-Legado-26051518'),
                release('V1.0.0.2', 'V1.0.0.0.2', ('Legado-Beta-26050716-unsigned.hap',)),
                release('v2', preview=True), release('Beta250302'), release('v3-rc1')]
        with patch.object(collector, '_json', return_value=rows):
            found = collector.fetch_releases('o/r')
        self.assertEqual(len(found), 6)
        self.assertEqual([r['tag'] for r in found if r['prerelease']], ['v2'])

    def test_stable_bodies_product_names_and_mixed_package_releases_stay_stable(self):
        rows = [release('v2', 'Fixed beta issues'), release('v3', 'BetaReader'),
                release('v4', assets=('stable.hap', 'app-beta.hap'))]
        rows[0]['name'] = 'v2'
        rows[0]['body'] = 'Fixed beta and preview issues'
        with patch.object(collector, '_json', return_value=rows):
            found = collector.fetch_releases('o/r')
        self.assertFalse(any(r['prerelease'] for r in found))

    def test_paginated_releases_keep_previews_on_later_pages(self):
        first = [release('v' + str(i)) for i in range(100)]
        last = [release('v101-beta', preview=True)]
        with patch.object(collector, '_json', side_effect=[first, last]) as get:
            found = collector.fetch_releases('o/r', token='test-token')
        self.assertEqual(len(found), 101)
        self.assertTrue(found[-1]['prerelease'])
        self.assertEqual(get.call_args_list[1].args[0], '/repos/o/r/releases?per_page=100&page=2')
        self.assertEqual(get.call_args.kwargs['token'], 'test-token')

    def test_failed_later_page_or_exceeded_limit_does_not_return_a_partial_snapshot(self):
        first = [release('v' + str(i)) for i in range(100)]
        with patch.object(collector, '_json', side_effect=[first, collector.CollectError('offline')]):
            with self.assertRaisesRegex(collector.CollectError, 'offline'):
                collector.fetch_releases('o/r')
        with patch.object(collector, '_json', return_value=first):
            with self.assertRaisesRegex(collector.CollectError, '采集上限'):
                collector.fetch_releases('o/r', limit=100)

    def test_latest_preview_is_inside_existing_three_release_parse_budget(self):
        rows = [{'tag': 'stable-' + str(i), 'assets': [{'name': 'app.hap'}], 'prerelease': False}
                for i in range(4)]
        preview = {'tag': 'old-beta', 'assets': [{'name': 'app-beta.hap'}], 'prerelease': True}
        rows.append(preview)
        order = collector.metadata_scan_order(rows)
        self.assertIs(order[0], rows[0]); self.assertIs(order[1], preview)
        self.assertEqual(len(order), len(rows)); self.assertIs(rows[-1], preview)

    def test_legacy_digest_is_derived_only_from_official_direct_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            package = os.path.join(tmp, 'old.hap')
            with zipfile.ZipFile(package, 'w') as z:
                z.writestr('pack.info', json.dumps({'summary': {'app': {
                    'bundleName': 'com.old.app', 'version': {'code': 1, 'name': '1.0'}}}}))
            with open(package, 'rb') as f:
                expected = hashlib.sha256(f.read()).hexdigest()
            asset = {'name': 'old.hap', 'sha256': '',
                     'download_url': 'https://github.com/o/r/releases/download/v1/old.hap'}
            with patch.object(collector, '_download_to_temp', return_value=package) as download:
                collector.enrich_assets_with_hap_metadata([{'assets': [asset]}])
            self.assertTrue(download.call_args.kwargs['direct_only'])
            self.assertEqual(asset['sha256'], expected)
            self.assertEqual(asset['bundle_name'], 'com.old.app')
        with patch.object(collector.urllib.request, 'urlopen') as get:
            self.assertIsNone(collector._download_to_temp('https://mirror.example/app.hap', direct_only=True))
        get.assert_not_called()


if __name__ == '__main__':
    unittest.main()
