import base64
import threading
import unittest
import tempfile
import os
import time
import urllib.error
from unittest.mock import patch
from server.hapstore import repository_readme as readme


def document(path, text='content'):
    return dict(path=path, size=len(text.encode()), content=base64.b64encode(text.encode()).decode(),
                html_url='https://github.com/example/app/blob/main/' + path,
                download_url='https://raw.githubusercontent.com/example/app/main/' + path)


class LocalizedReadmeTests(unittest.TestCase):
    def setUp(self):
        readme._pending.clear()
        temporary = tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        env = patch.dict(os.environ, {'HAPSTORE_README_CACHE': temporary.name})
        env.start();self.addCleanup(env.stop)

    def test_chinese_root_variant_is_rendered_instead_of_default(self):
        calls = []
        def upstream(repo, suffix, **kwargs):
            calls.append(suffix)
            if suffix == '/readme': return document('README.md', 'English')
            if suffix == '/contents': return [dict(type='file', path='README.zh-TW.md'), dict(type='file', path='README_zh-CN.md')]
            if suffix == '/contents/README_zh-CN.md': return document('README_zh-CN.md', '中文介绍')
            self.fail(suffix)
        with patch.object(readme, '_repository_json', side_effect=upstream), patch.object(readme.collector, '_http_get', return_value='<h1>中文介绍</h1>'.encode()) as render:
            result = readme.get('example/app', language='zh-CN')
        self.assertIn('README_zh-CN.md', result['source_url'])
        self.assertIn('中文介绍', result['html'])
        render.assert_not_called()
        self.assertEqual(len(calls), 3)

    def test_nested_language_link_avoids_repository_listing_and_rejects_external_links(self):
        default = document('README.md', '[中文](docs/zh-CN/README.md) [fake](https://evil.invalid/README.zh-CN.md)')
        with patch.object(readme, '_repository_json', return_value=document('docs/zh-CN/README.md')) as fetch:
            selected = readme._localized('example/app', '', 'zh', default)
        self.assertEqual(selected['path'], 'docs/zh-CN/README.md')
        self.assertEqual(fetch.call_args.args[1], '/contents/docs/zh-CN/README.md')
        self.assertEqual(fetch.call_count, 1)

    def test_missing_or_unreadable_translation_keeps_original(self):
        default = document('README.md')
        for value in [[], OSError('upstream unavailable')]:
            with patch.object(readme, '_repository_json', side_effect=value if isinstance(value, Exception) else None, return_value=value):
                self.assertIs(readme._localized('example/app', '', 'zh', default), default)
        with patch.object(readme, '_repository_json', side_effect=[
            [dict(type='file', path='README.zh.md')], OSError('translation deleted')]):
            self.assertIs(readme._localized('example/app', '', 'zh', default), default)

    def test_localized_default_does_not_add_upstream_queries(self):
        default = document('README.zh-CN.md')
        with patch.object(readme, '_repository_json') as fetch:
            self.assertIs(readme._localized('example/app', '', 'zh', default), default)
        fetch.assert_not_called()

    def test_english_html_link_is_selected_from_a_chinese_default(self):
        default = document('README.md', '# 中文\n<a href="./docs/en/README.md">English</a>')
        with patch.object(readme, '_repository_json', side_effect=[default, document('docs/en/README.md', '# English')]) as fetch:
            result = readme.get('example/app', language='en-US')
        self.assertIn('<h1>English</h1>', result['html'])
        self.assertEqual(fetch.call_args.args[1], '/contents/docs/en/README.md')

    def test_broken_language_link_falls_through_to_a_root_translation(self):
        default = document('README.md', '# English\n[中文][cn]\n\n[cn]: docs/README.zh.md')
        listing = [dict(type='file', path='README_zh-Hans.md')]
        with patch.object(readme, '_repository_json', side_effect=[default, OSError('stale link'),
            listing, document('README_zh-Hans.md', '# 中文介绍')]) as fetch:
            result = readme.get('example/app', language='zh')
        self.assertIn('中文介绍', result['html'])
        self.assertEqual([call.args[1] for call in fetch.call_args_list],
                         ['/readme', '/contents/docs/README.zh.md', '/contents', '/contents/README_zh-Hans.md'])

    def test_localized_only_repository_without_default_readme(self):
        missing = urllib.error.HTTPError('https://api.github.com', 404, '', {}, None)
        with patch.object(readme, '_repository_json', side_effect=[missing, [dict(type='file', path='README.zh.md')], document('README.zh.md')]), patch.object(readme.collector, '_http_get', return_value=b'<p>local</p>'):
            self.assertTrue(readme.get('example/app', language='zh')['found'])

    def test_language_requests_are_fresh_and_unsupported_languages_are_normalized(self):
        with patch.object(readme, '_render', side_effect=lambda repo, token, language: dict(found=True, html=language, source_url='')) as render:
            self.assertEqual(readme.get('example/app', language='zh-CN')['html'], 'zh')
            self.assertEqual(readme.get('example/app', language='en')['html'], 'en')
            self.assertEqual(readme.get('example/app', language='zh')['html'], 'zh')
            self.assertEqual(readme.get('example/app', language='anything')['html'], '')
            self.assertEqual(readme.get('example/app', language='another')['html'], '')
        self.assertEqual(render.call_count, 5)

    def test_same_locale_concurrent_reads_coalesce(self):
        entered, release = threading.Event(), threading.Event()
        def render(*args):
            entered.set()
            self.assertTrue(release.wait(2))
            return dict(found=True, html='中文', source_url='')
        results = []
        with patch.object(readme, '_render', side_effect=render) as fetch:
            first = threading.Thread(target=lambda: results.append(readme.get('example/app', language='zh')))
            second = threading.Thread(target=lambda: results.append(readme.get('example/app', language='zh-CN')))
            first.start(); self.assertTrue(entered.wait(2)); second.start(); release.set()
            first.join(2); second.join(2)
        self.assertEqual(len(results), 2)
        self.assertEqual(fetch.call_count, 1)

    def test_localized_html_retains_passive_sanitization(self):
        with patch.object(readme, '_repository_json', return_value=document('README.zh.md', '<script>bad</script><p onclick="bad()">hello</p><img src="./icon.png">')):
            result = readme.get('example/app', language='zh')
        self.assertNotIn('script', result['html'])
        self.assertNotIn('onclick', result['html'])
        self.assertIn('https://raw.githubusercontent.com/example/app/main/icon.png', result['html'])

    def test_local_gfm_render_does_not_make_a_second_github_html_request(self):
        markdown = '# Title\n\n| A | B |\n|---|---|\n| one | two |\n\n- [x] done\n\n~~old~~\n\n![device](./device.png)'
        with patch.object(readme, '_repository_json', return_value=document('README.md', markdown)), \
             patch.object(readme.collector, '_http_get', side_effect=AssertionError('duplicate remote render')):
            result = readme.get('example/app')
        for item in ['<h1>', '<table>', 'checkbox', '<del>', 'https://raw.githubusercontent.com/example/app/main/device.png']:
            self.assertIn(item, result['html'])

    def test_completed_reads_always_fetch_fresh_without_memory_or_disk_cache(self):
        values = [dict(found=True, html=str(i), source_url='https://github.com/example/app/') for i in range(2)]
        with patch.object(readme, '_render', side_effect=values) as fetch:
            self.assertEqual(readme.get('example/app')['html'], '0')
            self.assertEqual(readme.get('example/app')['html'], '1')
            self.assertEqual(fetch.call_count, 2)
        self.assertEqual(readme._pending, {})
        self.assertNotIn('_cache', vars(readme))
        self.assertNotIn('_read_disk', vars(readme))

    def test_upstream_errors_are_reported_and_a_new_view_can_retry_immediately(self):
        value = dict(found=True, html='new', source_url='https://github.com/example/app/')
        with patch.object(readme, '_render', side_effect=[OSError('unavailable'), value]) as fetch:
            with self.assertRaises(OSError): readme.get('example/app')
            self.assertEqual(readme.get('example/app'), value)
            self.assertEqual(fetch.call_count, 2)

    def test_raw_source_fetch_sends_no_etag_and_bypasses_collector_payload_cache(self):
        from io import BytesIO
        response = BytesIO(b'{"path":"README.md"}')
        with patch.object(readme.urllib.request, 'urlopen', return_value=response) as fetch, \
             patch.object(readme.collector, '_repository_json', side_effect=AssertionError('cached collector used')):
            self.assertEqual(readme._repository_json('example/app', '/readme')['path'], 'README.md')
            headers = {k.lower():v for k,v in fetch.call_args.args[0].header_items()}
            self.assertEqual(headers['cache-control'], 'no-cache')
            self.assertNotIn('if-none-match', headers)

    def test_read_has_bounded_wait_and_late_completion_is_not_cached(self):
        release = threading.Event()
        def slow(*args): release.wait(2);return dict(found=True, html='old')
        with patch.object(readme, '_render', side_effect=slow), patch.object(readme, 'READ_WAIT_SECONDS', .02):
            start = time.monotonic()
            with self.assertRaises(TimeoutError): readme.get('example/app')
            self.assertLess(time.monotonic() - start, .2)
            waiter = readme._pending[('example/app', '')];release.set();self.assertTrue(waiter.done.wait(2))
        with patch.object(readme, '_render', return_value=dict(found=True, html='latest')) as fetch:
            self.assertEqual(readme.get('example/app')['html'], 'latest')
            fetch.assert_called_once()


if __name__ == '__main__': unittest.main()
