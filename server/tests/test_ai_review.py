"""Review jobs are bounded; automatic decisions preserve evidence and operator intent."""
import json
import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from server.hapstore import ai_review as ai, db, distribution


class AiReviewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old = db.DB_PATH
        db.DB_PATH = self.tmp.name + '/db.sqlite'
        db._local = threading.local()
        db._initialized = False
        ai._stop.clear()
        ai._fatal.clear()
        ai.init()
        self.app_id = db.upsert_app('example/reader', display_name='Reader', description='Local reader')
        self.payload = dict(name='Reader', description='Local reader', readme='A local reader.', manifest='[]', operator='')
        self.good = dict(region='ordinary', confidence='high', purpose='Local reading', reason='Local reader',
                         evidence=[dict(source='readme', quote='A local reader.')], needs_manual_review=False)

    def tearDown(self):
        db.connect().close()
        db.DB_PATH = self.old
        db._local = threading.local()
        db._initialized = False
        ai._fatal.clear()
        self.tmp.cleanup()

    def enqueue(self):
        with patch.object(ai, 'input_for', return_value=self.payload):
            return ai.enqueue_all()

    def ready(self, result=None, payload=None):
        with patch.object(ai, 'input_for', return_value=payload or self.payload):
            ai.enqueue_all(app_ids=[self.app_id])
        job_id=db.connect().execute('SELECT job_id FROM ai_review_current WHERE app_id=?',(self.app_id,)).fetchone()[0]
        result=result or self.good
        with db.connect() as conn:
            conn.execute("UPDATE ai_review_job SET status='ready',proposed_region=?,result_json=? WHERE id=?",
                         (result['region'],json.dumps(result),job_id))
        return job_id

    def test_dedup_and_changed_metadata_enqueue_only_new_evidence(self):
        self.assertEqual(self.enqueue()['queued'], 1)
        self.assertEqual(self.enqueue()['queued'], 0)
        self.payload['description'] = 'Updated reader'
        self.assertEqual(self.enqueue()['queued'], 1)

    def test_shadow_result_cannot_change_effective_region_or_listing(self):
        with db.connect() as c:
            c.execute('INSERT INTO app_distribution(app_id,region,review_source,reason,updated_at) VALUES(?,?,?,?,?)',
                      (self.app_id, 'overseas', 'operator-explicit', 'Keep existing', 1))
        before = tuple(db.connect().execute('SELECT * FROM app_distribution').fetchone())
        self.enqueue()
        with patch.object(ai, 'call_model', return_value=(self.good, dict(prompt_tokens=12, completion_tokens=4))):
            self.assertTrue(ai.process_one())
            self.assertFalse(ai.process_one())
        self.assertEqual(tuple(db.connect().execute('SELECT * FROM app_distribution').fetchone()), before)
        self.assertEqual(db.get_app(self.app_id)['status'], 'published')
        self.assertEqual(ai.summary()['jobs'], {'ready': 1})

    def test_evidence_requires_verbatim_quote(self):
        invalid=ai.validate_result(dict(self.good, evidence=[dict(source='readme', quote='VPN client')]), self.payload)
        self.assertEqual(invalid['region'], 'review')
        self.assertTrue(invalid['needs_manual_review'])
        self.assertEqual(invalid['evidence'], [])
        self.assertEqual(ai.validate_result(self.good, self.payload)['region'], 'ordinary')

    def test_empty_evidence_and_low_confidence_require_manual_review(self):
        result = ai.validate_result(dict(self.good, evidence=[]), self.payload)
        self.assertEqual((result['region'], result['confidence'], result['needs_manual_review']), ('review', 'low', True))
        self.assertTrue(ai.validate_result(dict(self.good, confidence='low'), self.payload)['needs_manual_review'])

    def test_operator_18plus_cannot_silently_become_ordinary(self):
        result = ai.validate_result(self.good, dict(self.payload, operator='Confirmed 18+'))
        self.assertEqual(result['region'], 'review')
        self.assertTrue(result['needs_manual_review'])

    def test_malformed_output_is_rejected(self):
        for value in ({}, None, [], dict(self.good, needs_manual_review='false'), dict(self.good, evidence='yes')):
            with self.subTest(value=value), self.assertRaises(ai.ReviewError):
                ai.validate_result(value, self.payload)

    def test_retry_budget_and_fatal_auth_stop(self):
        self.enqueue()
        with patch.object(ai, 'call_model', side_effect=ai.ReviewError('AI_NETWORK_ERROR')):
            for _ in range(3):
                self.assertTrue(ai.process_one())
                with db.connect() as c:
                    c.execute('UPDATE ai_review_job SET next_at=0')
            self.assertFalse(ai.process_one())
        self.assertEqual(ai.summary()['jobs'], {'failed': 1})
        self.payload['name'] = 'Another'
        self.enqueue()
        with patch.object(ai, 'call_model', side_effect=ai.ReviewError('AI_HTTP_401', fatal=True)):
            ai.process_one()
            self.assertTrue(ai._fatal.is_set())
            self.assertFalse(ai.process_one())

    def test_only_official_https_endpoint_and_shadow_mode(self):
        for url in ('http://api.deepseek.com/chat/completions', 'https://evil.example/chat/completions',
                    'https://api.deepseek.com.evil.example/chat/completions', 'https://api.deepseek.com/chat/completions?key=x'):
            with patch.dict(os.environ, {'HAPSTORE_AI_REVIEW_URL': url}), self.assertRaises(ai.ReviewError):
                ai.call_model(self.payload)
        with patch.dict(os.environ, {'HAPSTORE_AI_REVIEW_KEY': 'test', 'HAPSTORE_AI_REVIEW_MODE': 'apply'}), self.assertRaises(ai.ReviewError):
            ai.call_model(self.payload)

    def test_secrets_scrubbed_before_public_evidence_import(self):
        evidence = Path(self.tmp.name) / 'evidence.json'
        evidence.write_text(json.dumps([dict(repo='example/reader', text='sk-' + 'x' * 30, status='ok', url='https://github.com/example/reader')]))
        self.assertEqual(ai.import_evidence(evidence), 1)
        self.assertNotIn('sk-', ai.readme('example/reader', '')['text'])
        self.assertEqual(ai.scrub('-----BEGIN PRIVATE KEY-----secret-----END PRIVATE KEY-----'), '[private material removed]')

    def test_auto_applies_verified_result_once_without_changing_listing_status(self):
        job_id=self.ready(dict(self.good,region='overseas'))
        with patch.dict(os.environ,{'HAPSTORE_AI_REVIEW_MODE':'auto'}):
            self.assertEqual(ai.apply_review(job_id),'applied')
            before=tuple(db.connect().execute('SELECT * FROM app_distribution').fetchone())
            self.assertEqual(ai.apply_review(job_id),'applied')
            self.assertEqual(tuple(db.connect().execute('SELECT * FROM app_distribution').fetchone()),before)
            self.assertEqual(ai.apply_ready(),{})
        self.assertEqual(db.connect().execute('SELECT COUNT(*) FROM ai_review_application').fetchone()[0],1)
        self.assertEqual(db.get_app(self.app_id)['status'],'published')
        with distribution.scope('ordinary'):
            self.assertFalse(distribution.allows(db.connect(),self.app_id))
        with distribution.scope('overseas'):
            self.assertTrue(distribution.allows(db.connect(),self.app_id))

    def test_auto_keeps_manual_decisions_and_cannot_remove_overseas_restrictions(self):
        with db.connect() as conn:
            conn.execute('INSERT INTO app_distribution(app_id,region,review_source,reason,updated_at) VALUES(?,?,?,?,?)',
                         (self.app_id,'overseas','operator-ai-approved','Approved by user',1))
        job_id=self.ready()
        with patch.dict(os.environ,{'HAPSTORE_AI_REVIEW_MODE':'auto'}):
            self.assertEqual(ai.apply_review(job_id),'protected')
            with db.connect() as conn:
                conn.execute("UPDATE app_distribution SET review_source='ai-auto'")
            job_id=self.ready(payload=dict(self.payload,name='Changed'))
            self.assertEqual(ai.apply_review(job_id),'protected')
        self.assertEqual(distribution.region(db.connect(),self.app_id),'overseas')

    def test_manual_review_keeps_existing_partition_and_shadow_never_applies(self):
        job_id=self.ready(dict(self.good,region='overseas',confidence='low',needs_manual_review=True))
        self.assertEqual(ai.apply_review(job_id),'shadow')
        with patch.dict(os.environ,{'HAPSTORE_AI_REVIEW_MODE':'auto'}):
            self.assertEqual(ai.apply_review(job_id),'review')
        self.assertEqual(distribution.region(db.connect(),self.app_id),'ordinary')
        self.assertEqual(db.connect().execute('SELECT COUNT(*) FROM app_distribution').fetchone()[0],0)

    def test_slow_old_inference_cannot_overwrite_the_current_payload(self):
        old=self.ready(dict(self.good,region='overseas'))
        current=self.ready(payload=dict(self.payload,name='New metadata'))
        with patch.dict(os.environ,{'HAPSTORE_AI_REVIEW_MODE':'auto'}):
            self.assertEqual(ai.apply_review(old),'superseded')
            self.assertEqual(ai.apply_review(current),'unchanged')
        self.assertEqual(distribution.region(db.connect(),self.app_id),'ordinary')

    def test_reverting_metadata_reuses_cached_inference_with_a_new_application_revision(self):
        first=self.ready()
        with patch.dict(os.environ,{'HAPSTORE_AI_REVIEW_MODE':'auto'}):
            self.assertEqual(ai.apply_review(first),'unchanged')
            second=self.ready(payload=dict(self.payload,name='Next'))
            self.assertEqual(ai.apply_review(second),'unchanged')
            reverted=self.ready()
            self.assertEqual(reverted,first)
            self.assertEqual(ai.apply_review(reverted),'unchanged')
        self.assertEqual(db.connect().execute('SELECT COUNT(*) FROM ai_review_job').fetchone()[0],2)
        self.assertEqual(db.connect().execute('SELECT COUNT(*) FROM ai_review_application').fetchone()[0],3)

    def test_new_listing_waits_for_async_review_and_becomes_visible_after_verified_result(self):
        with patch.dict(os.environ,{'HAPSTORE_AI_REVIEW_MODE':'auto'}):
            ai.init()
            new,_,_=db.apply_catalog_snapshot('example/new-reader',
                dict(display_name='Reader',description='Local reader',status='published'),[])
            self.assertEqual(distribution.region(db.connect(),new),'review')
            with distribution.scope('ordinary'):
                self.assertFalse(any(a['id']==new for a in db.list_apps()['items']))
            with patch.object(ai,'input_for',return_value=self.payload):
                self.assertEqual(ai.enqueue_signaled()['queued'],1)
            with patch.object(ai,'call_model',return_value=(self.good,dict(prompt_tokens=1,completion_tokens=1))) as call:
                self.assertTrue(ai.process_one());call.assert_called_once()
            self.assertEqual(distribution.region(db.connect(),new),'ordinary')
            with distribution.scope('ordinary'):
                self.assertTrue(any(a['id']==new for a in db.list_apps()['items']))

    def test_pending_change_defers_apply_and_cas_signal_consumption_keeps_racing_changes(self):
        job_id=self.ready(dict(self.good,region='overseas'))
        with db.connect() as conn:
            conn.execute('INSERT INTO ai_review_signal(app_id,revision,updated_at) VALUES(?,1,1)',(self.app_id,))
        with patch.dict(os.environ,{'HAPSTORE_AI_REVIEW_MODE':'auto'}):
            self.assertEqual(ai.apply_review(job_id),'deferred')
        def racing_enqueue(*_):
            with db.connect() as conn:conn.execute('UPDATE ai_review_signal SET revision=revision+1')
            return dict(scanned=1,queued=0)
        with patch.object(ai,'enqueue_all',side_effect=racing_enqueue):ai.enqueue_signaled()
        self.assertEqual(db.connect().execute('SELECT revision FROM ai_review_signal').fetchone()[0],2)
        with patch.object(ai,'input_for',return_value=self.payload):ai.enqueue_signaled()
        with patch.dict(os.environ,{'HAPSTORE_AI_REVIEW_MODE':'auto'}):
            self.assertEqual(ai.apply_review(job_id),'applied')

    def test_first_activation_preserves_legacy_listings_and_restart_keeps_new_apps_pending(self):
        with patch.dict(os.environ,{'HAPSTORE_AI_REVIEW_MODE':'auto'}):
            ai.init()
            db.apply_catalog_snapshot('example/reader',dict(description='Local reader'),[])
            self.assertEqual(distribution.region(db.connect(),self.app_id),'ordinary')
            new,_,_=db.apply_catalog_snapshot('example/new',dict(display_name='New'),[])
            self.assertEqual(distribution.region(db.connect(),new),'review')
            ai.init()
            self.assertEqual(distribution.region(db.connect(),new),'review')

    def test_transient_application_error_reuses_completed_inference_instead_of_calling_model_again(self):
        self.enqueue()
        with patch.dict(os.environ,{'HAPSTORE_AI_REVIEW_MODE':'auto'}):
            with patch.object(ai,'call_model',return_value=(self.good,dict(prompt_tokens=1,completion_tokens=1))) as call:
                with patch.object(ai,'apply_review',side_effect=OSError('busy')):ai.process_one()
                self.assertEqual(ai.summary()['jobs'],{'ready':1})
                self.assertEqual(ai.apply_ready(),{'unchanged':1})
                self.assertFalse(ai.process_one());call.assert_called_once()


if __name__ == '__main__':
    unittest.main()
