"""Personal management survives regional discovery filtering; identities never share grants."""
import http.client
import json
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch
from server.hapstore import app, db, distribution, personal_catalog as personal
try:
    from server.hapstore import following, update_push
except ImportError:
    following=update_push=None


class PersonalCatalogTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.old=db.DB_PATH
        db.DB_PATH=self.temp.name+'/db.sqlite';db._local=threading.local();db._initialized=False;db.init_db()
        db.connect().executescript('''CREATE TABLE IF NOT EXISTS app_follow(account_id TEXT,app_id INTEGER,
          prerelease INTEGER DEFAULT 0,muted INTEGER DEFAULT 0,baseline_release_id INTEGER DEFAULT 0,
          created_at INTEGER,updated_at INTEGER,PRIMARY KEY(account_id,app_id));
          CREATE TABLE IF NOT EXISTS update_push_watch(account_id TEXT,client_id TEXT,app_id INTEGER,
          bundle_name TEXT,installed_code INTEGER,last_queued_code INTEGER,PRIMARY KEY(account_id,client_id,app_id,bundle_name));''')
        self.foreign=db.upsert_app('example/foreign',display_name='Foreign')
        self.ordinary=db.upsert_app('example/ordinary',display_name='Ordinary')
        for aid in [self.foreign,self.ordinary]:
            db.replace_releases(aid,[dict(tag='v2',published_at='2026-11-13T01:00:00Z',assets=[dict(name='app.hap',size=1,bundle_name=f'com.app{aid}',version_code=2,download_url='https://example.com/app.hap')])])
        with db.connect() as c:
            c.execute('INSERT INTO app_distribution(app_id,region,review_source,updated_at) VALUES(?,?,?,?)',(self.foreign,'overseas','test',1))
        app._rl.clear()

    def tearDown(self):
        db.connect().close();db.DB_PATH=self.old;db._local=threading.local();db._initialized=False;self.temp.cleanup()

    def inventory(self,client='phone',app_id=None,bundle=None):
        aid=app_id or self.foreign
        return dict(client_id=client,items=[dict(app_id=aid,bundle_name=bundle or f'com.app{aid}',version_code=1)])

    def follow(self,account='alice'):
        with db.connect() as c:
            c.execute('INSERT INTO app_follow(account_id,app_id,prerelease,muted,baseline_release_id,created_at,updated_at) VALUES(?,?,0,0,0,1,1)',(account,self.foreign))

    def test_inventory_matches_exact_bundle_and_does_not_grant_other_accounts(self):
        personal.sync('alice',self.inventory(bundle='com.wrong'))
        self.assertFalse(personal.allows('alice',self.foreign))
        with distribution.scope('ordinary'):
            result=personal.sync('alice',self.inventory())
            self.assertEqual([a['id'] for a in result['items']],[self.foreign])
            self.assertNotIn(self.foreign,[a['id'] for a in db.list_apps()['items']])
        self.assertTrue(personal.allows('alice',self.foreign))
        self.assertFalse(personal.allows('bob',self.foreign))
        self.assertFalse(personal.allows('',self.foreign))

    def test_inventory_cleanup_only_affects_its_device_and_retains_followed_apps(self):
        personal.sync('alice',self.inventory('phone'));personal.sync('alice',self.inventory('tablet'))
        personal.sync('alice',dict(client_id='phone',items=[]))
        self.assertTrue(personal.allows('alice',self.foreign))
        personal.sync('alice',dict(client_id='tablet',items=[]))
        self.assertFalse(personal.allows('alice',self.foreign))
        self.follow();personal.sync('alice',dict(client_id='phone',items=[]))
        self.assertTrue(personal.allows('alice',self.foreign))

    def test_unambiguous_bundle_matching_and_malformed_inventory(self):
        item=self.inventory();item['items'][0]['app_id']=0
        self.assertEqual([r['id'] for r in personal.sync('alice',item)['items']],[self.foreign])
        for body in [dict(client_id='bad/path',items=[]),dict(items='bad'),dict(items=[dict(app_id=True,bundle_name='x',version_code=1)])]:
            with self.subTest(body=body),self.assertRaises(ValueError):personal.sync('alice',body)

    def test_hidden_apps_stay_hidden_from_personal_library(self):
        personal.sync('alice',self.inventory())
        with db.connect() as c:c.execute("UPDATE app SET status='hidden' WHERE id=?",(self.foreign,))
        self.assertEqual(personal.library('alice')['items'],[])

    def test_personal_detail_and_versions_work_in_cn_but_browse_never_bypasses_filter(self):
        self.follow()
        db.set_publisher(self.foreign, 'publisher', 'Owner')
        server=ThreadingHTTPServer(('127.0.0.1',0),app.Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        def identity(handler):
            user=handler.headers.get('Authorization','').removeprefix('Bearer ')
            if user not in ('alice','bob','publisher'):raise app.ApiError(401,'SIGN_IN_REQUIRED','登录')
            return user,user
        def request(path,user=''):
            conn=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=4)
            headers={'X-Real-IP':'114.114.114.114'}
            if user:headers['Authorization']='Bearer '+user
            conn.request('GET',path,headers=headers);response=conn.getresponse();data=json.loads(response.read());status=response.status;conn.close();return status,data
        try:
            with patch.object(distribution,'country',return_value='CN'),patch.object(app.Handler,'_identity',identity):
                self.assertEqual(request(f'/api/v1/apps/{self.foreign}')[0],404)
                self.assertEqual(request(f'/api/v1/apps/{self.foreign}','bob')[0],404)
                self.assertEqual(request(f'/api/v1/apps/{self.foreign}','alice')[0],200)
                self.assertEqual(request(f'/api/v1/apps/{self.foreign}/releases','alice')[0],200)
                # Owners can manage their listing without first installing or following it.
                mine=request('/api/v1/me/apps','publisher')[1]['data']['items']
                self.assertEqual([row['id'] for row in mine],[self.foreign])
                self.assertEqual(request('/api/v1/me/apps','bob')[1]['data']['items'],[])
                self.assertEqual(request('/api/v1/me/apps')[0],401)
                self.assertEqual(request(f'/api/v1/apps/{self.foreign}','publisher')[0],200)
                self.assertEqual(request(f'/api/v1/apps/{self.foreign}/releases','publisher')[0],200)
                browse=request('/api/v1/apps','alice')[1]['data']
                self.assertNotIn(self.foreign,[r['id'] for r in browse['items']])
                self.assertEqual(request('/api/v1/collections?key=overseas','alice')[0],404)
        finally:server.shutdown();server.server_close();thread.join()

    def test_publisher_listing_is_independent_of_network_and_region_filters(self):
        db.set_publisher(self.foreign,'alice','Owner')
        db.set_publisher(self.ordinary,'alice','Owner')
        for scope in ('ordinary','overseas'):
            with self.subTest(scope=scope),distribution.scope(scope),distribution.only_region('ordinary'):
                self.assertEqual({row['id'] for row in db.list_published_by_account('alice')},
                                 {self.foreign,self.ordinary})
                self.assertEqual(db.list_published_by_account('bob'),[])
        with db.connect() as conn:conn.execute("UPDATE app SET status='hidden' WHERE id=?",(self.foreign,))
        with distribution.scope('ordinary'):
            self.assertEqual([row['id'] for row in db.list_published_by_account('alice')],[self.ordinary])

    @unittest.skipIf(update_push is None,'Production notification module validated in deployed-source preflight')
    def test_followed_and_installed_apps_queue_and_deliver_once_even_from_cn(self):
        self.follow()
        with db.connect() as c:
            for user in ['alice','bob']:
                c.execute('INSERT INTO update_push_target(account_id,client_id,nickname,enabled,verified_at,updated_at,deep_link) VALUES(?,?,?,1,1,1,1)',(user,'phone','test-'+user))
            c.execute('INSERT INTO update_push_watch(account_id,client_id,app_id,bundle_name,installed_code,last_queued_code) VALUES(?,?,?,?,1,1)',('bob','phone',self.foreign,f'com.app{self.foreign}'))
        with distribution.scope('ordinary'):
            self.assertEqual([r['app']['id'] for r in following.state('alice')['items']],[self.foreign])
            self.assertEqual(update_push.queue_updates(self.foreign,[]),2)
            self.assertEqual(update_push.queue_updates(self.foreign,[]),0)
            with patch.object(update_push,'_send_meow') as send:
                self.assertTrue(update_push._deliver_ready());self.assertTrue(update_push._deliver_ready())
                self.assertFalse(update_push._deliver_ready());self.assertEqual(send.call_count,2)
                self.assertTrue(all(call.kwargs['link'].startswith('qingqi-installer://') for call in send.call_args_list))

    @unittest.skipIf(update_push is None,'Production notification module validated in deployed-source preflight')
    def test_authenticated_update_check_registers_inventory_without_revealing_public_catalog(self):
        with distribution.scope('ordinary'):
            result=update_push.available_updates(self.inventory()['items'],'alice')
            self.assertEqual(len(result['items']),1)
            self.assertTrue(personal.allows('alice',self.foreign))
            self.assertFalse(personal.allows('bob',self.foreign))
            self.assertNotIn(self.foreign,[r['id'] for r in db.list_apps()['items']])


if __name__=='__main__':unittest.main()
