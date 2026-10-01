"""采集端的信任边界回归测试。"""

import json
import os
import tempfile
import zipfile
import unittest
from unittest.mock import patch

from server.hapstore import collector


class CollectorSecurityTest(unittest.TestCase):
    def test_release_digest_only_comes_from_direct_github_api(self):
        digest = "a" * 64
        payload = [{
            "tag_name": "v1",
            "assets": [{
                "name": "app.hap",
                "digest": f"sha256:{digest}",
                "browser_download_url": "https://github.com/o/r/releases/download/v1/app.hap",
            }],
        }]
        with patch.object(collector, "_http_get", return_value=json.dumps(payload).encode()) as get:
            releases = collector.fetch_releases("o/r", token="private-token")
        self.assertEqual(releases[0]["assets"][0]["sha256"], digest)
        self.assertEqual(get.call_args.args[0],
                         "https://api.github.com/repos/o/r/releases?per_page=30")
        self.assertEqual(get.call_args.kwargs["token"], "private-token")

    def test_malformed_github_digest_is_not_published(self):
        payload = [{"assets": [{"name": "app.hap", "digest": "sha256:wrong"}]}]
        with patch.object(collector, "_http_get", return_value=json.dumps(payload).encode()):
            releases = collector.fetch_releases("o/r")
        self.assertEqual(releases[0]["assets"][0]["sha256"], "")

    def test_plain_hap_rejects_oversized_expanded_manifest_before_read(self):
        with tempfile.TemporaryDirectory() as temp:
            path = os.path.join(temp, 'large.hap')
            with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as z:
                z.writestr('pack.info', '{}' + ' ' * (4 * 1024 * 1024))
            with self.assertRaisesRegex(collector.CollectError, '超限'):
                collector.parse_hap_metadata(path)

    def test_plain_hap_rejects_duplicate_manifests(self):
        import warnings
        with tempfile.TemporaryDirectory() as temp, warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            path = os.path.join(temp, 'duplicate.hap')
            with zipfile.ZipFile(path, 'w') as z:
                z.writestr('module.json', '{}')
                z.writestr('module.json', '{}')
            with self.assertRaisesRegex(collector.CollectError, '重复'):
                collector.parse_hap_metadata(path)


if __name__ == "__main__":
    unittest.main()
