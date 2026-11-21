"""Network isolation is checked before pagination, totals, links and conditional caching."""
import http.client
import json
import os
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from types import SimpleNamespace
from unittest.mock import Mock, patch
from server.hapstore import app, db, distribution


class DistributionTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.old=db.DB_PATH
        db.DB_PATH=self.temp.name+'/store.db';db._local=threading.local();db._initialized=False;db.init_db()
        self.ids=[]
        now=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
        for index,(region,status,category) in enumerate([('ordinary','published','影音'),('overseas','published','工具'),('ordinary','hidden','阅读'),('review','published','游戏')]):
            aid=db.upsert_app(f'dev/app{index}',display_name=f'App {index}',status=status,category=category,stars=1000-index)
            self.ids.append(aid)
            db.replace_releases(aid,[dict(tag='v1',published_at=now,prerelease=False,assets=[dict(name='app.hap',size=2,download_url='https://github.com/dev/a/releases/download/v1/app.hap',bundle_name=f'com.example.app{index}',version_code=1)])])
            db.connect().execute('INSERT INTO app_distribution(app_id,region,review_source,updated_at) VALUES(?,?,?,?)',(aid,region,'test',int(time.time())))
        db.connect().commit();app._rl.clear()

    def tearDown(self):
        db.connect().close();db.DB_PATH=self.old;db._local=threading.local();db._initialized=False;self.temp.cleanup()

    def ids_for(self,mode,**options):
        with distribution.scope(mode):return [r['id'] for r in db.list_apps(**options)['items']]

    def test_filter_runs_before_limits_and_counts_for_all_sort_modes(self):
        for sort in ('updated','stars','downloads','new','name','discover'):
            with distribution.scope('ordinary'):
                rows=db.list_apps(sort=sort,page_size=1)
                self.assertEqual((rows['total'],[r['id'] for r in rows['items']]),(1,[self.ids[0]]))
                self.assertEqual(db.list_apps(q='App 1')['total'],0)
                self.assertEqual(db.list_apps(category='工具')['total'],0)
            self.assertEqual(set(self.ids_for('overseas',sort=sort)),set(self.ids[:2]))

    def test_reused_connection_and_prepared_sql_never_keep_previous_scope(self):
        for mode,expected in [('overseas',2),('ordinary',1),('overseas',2),('ordinary',1)]:
            with distribution.scope(mode):
                self.assertEqual(db.list_apps()['total'],expected)

    def test_pagination_tokens_do_not_cross_network_scopes(self):
        with distribution.scope('overseas'):
            first=db.list_apps(sort='stars',pagination='snapshot',page_size=1)
        with distribution.scope('ordinary'):
            result=db.list_apps(sort='stars',pagination='snapshot',page_size=1,snapshot=first['snapshot'])
            self.assertTrue(result['snapshot_expired']);self.assertEqual(result['items'],[])

    def test_discovery_all_shelves_categories_and_overseas_flag_match(self):
        db.record_discovery_stars()
        with distribution.scope('ordinary'):
            data=db.list_collections();self.assertFalse(data['show_overseas_section'])
            self.assertNotIn('overseas',[r['key'] for r in data['blocks']])
            self.assertEqual([r['category'] for r in data['categories']],['影音'])
            for block in data['blocks']:
                self.assertTrue(all(r['id']==self.ids[0] for r in block['items']))
        with distribution.scope('overseas'):
            data=db.list_collections();self.assertTrue(data['show_overseas_section'])
            block=next(b for b in data['blocks'] if b['key']=='overseas')
            self.assertEqual([r['id'] for r in block['items']],[self.ids[1]])
            self.assertEqual(data['network_scope'],'overseas')
            self.assertEqual(distribution.cache_key(),('overseas',''))

    def test_network_switch_removes_section_without_republishing_hidden_app(self):
        with distribution.scope('overseas'):
            self.assertTrue(distribution.flags(db.connect())['show_overseas_section'])
        with distribution.scope('ordinary'):
            self.assertFalse(distribution.flags(db.connect())['show_overseas_section'])
        self.assertEqual(db.get_app(self.ids[2])['status'],'hidden')

    def test_region_is_explicit_on_all_catalog_cards_without_per_card_queries(self):
        statements=[]
        db.connect().set_trace_callback(statements.append)
        try:
            with distribution.scope('overseas'):
                apps=db.list_apps(page_size=100)['items']
            regions={a['id']:a['distribution_region'] for a in apps}
            self.assertEqual(regions,{self.ids[0]:'ordinary',self.ids[1]:'overseas'})
            reads=[s for s in statements if s.startswith('SELECT a.id AS app_id,i.digest,COALESCE(d.region')]
            self.assertEqual(len(reads),1)
            with distribution.scope('overseas'):
                block=db.list_collections(key='overseas')['blocks'][0]
            self.assertTrue(all(a['distribution_region']=='overseas' for a in block['items']))
        finally:
            db.connect().set_trace_callback(None)

    def test_request_scope_resets_after_exception(self):
        with patch.object(distribution,'country',return_value='CN'):
            with self.assertRaises(ValueError):
                with distribution.request('114.114.114.114'):
                    self.assertEqual(distribution.cache_key()[0],'ordinary');raise ValueError()
        self.assertEqual(distribution.cache_key()[0],'internal')

    def test_unknown_country_is_restricted_and_vpn_headers_are_ignored(self):
        for iso in ('','CN'):
            with patch.object(distribution,'country',return_value=iso):
                with distribution.request('8.8.8.8'):
                    self.assertEqual(distribution.cache_key()[0],'ordinary')
        with patch.object(distribution,'country',return_value='US'):
            with distribution.request('8.8.8.8'):
                self.assertEqual(distribution.cache_key()[0],'overseas')

    def test_parallel_requests_are_isolated(self):
        barrier=threading.Barrier(2)
        def read(mode):
            try:
                with distribution.scope(mode):
                    barrier.wait();return db.list_apps()['total']
            finally:db.connect().close()
        with ThreadPoolExecutor(max_workers=2) as pool:
            a=pool.submit(read,'ordinary');b=pool.submit(read,'overseas')
            self.assertEqual((a.result(),b.result()),(1,2))

    def test_server_push_never_infers_receiver_region_from_previous_requests(self):
        with distribution.scope('overseas'):
            self.assertTrue(distribution.ordinary_notice(db.connect(),self.ids[0]))
            self.assertFalse(distribution.ordinary_notice(db.connect(),self.ids[1]))
            self.assertFalse(distribution.ordinary_notice(db.connect(),self.ids[3]))

    def test_bootstrap_does_not_change_listing_status_or_existing_review(self):
        a=db.upsert_app('dev/new',display_name='New')
        with db.connect() as c:
            distribution.bootstrap_review(c,a,dict(display_name='Proxy setting',description='Reader supports proxy settings'))
            self.assertEqual(distribution.region(c,a),'ordinary')
            distribution.bootstrap_review(c,a,dict(description='An open source proxy client based on Mihomo'))
            self.assertEqual(distribution.region(c,a),'overseas')
            distribution.bootstrap_review(c,a,dict(description='普通软件'))
            self.assertEqual(distribution.region(c,a),'overseas')
        self.assertEqual(db.get_app(a)['status'],'published')

    def test_http_public_detail_release_icon_and_readme_guard_runs_before_cache(self):
        server=ThreadingHTTPServer(('127.0.0.1',0),app.Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        def get(path,ip,etag=''):
            connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=5)
            connection.request('GET',path,headers={'X-Real-IP':ip,'If-None-Match':etag,'CF-IPCountry':'US','X-Forwarded-For':'8.8.8.8'})
            r=connection.getresponse();data=r.read();headers=dict(r.getheaders());connection.close();return r.status,data,headers
        try:
            with patch.object(distribution,'country',side_effect=lambda ip:'US' if ip=='8.8.8.8' else 'CN'):
                for suffix in ('','/releases','/releases/v1','/icon','/readme','/reviews','/refresh-status'):
                    self.assertEqual(get(f'/api/v1/apps/{self.ids[1]}'+suffix,'114.114.114.114','"old-overseas-etag"')[0],404)
                status,data,headers=get(f'/api/v1/apps/{self.ids[1]}','8.8.8.8')
                self.assertEqual(status,200);self.assertEqual(json.loads(data)['data']['distribution_region'],'overseas')
                self.assertTrue(headers['Cache-Control'].startswith('private'))
                self.assertEqual(get(f'/api/v1/apps/{self.ids[2]}','8.8.8.8')[0],404)
                self.assertEqual(get('/api/v1/collections?key=overseas','114.114.114.114')[0],404)
                self.assertTrue(json.loads(get('/api/v1/distribution','8.8.8.8')[1])['data']['show_overseas_section'])
        finally:server.shutdown();server.server_close();thread.join(2)


class GeoAndProxyTest(unittest.TestCase):
    def test_only_trusted_loopback_proxy_can_supply_real_ip(self):
        for peer,headers,expected in [('9.9.9.9',{'X-Real-IP':'8.8.8.8'},'9.9.9.9'),('127.0.0.1',{'X-Real-IP':'8.8.8.8'},'8.8.8.8'),('::1',{'X-Forwarded-For':'8.8.8.8'},'::1'),('127.0.0.1',{'X-Real-IP':'garbage'},'')]:
            self.assertEqual(distribution.client_ip(SimpleNamespace(client_address=(peer,1),headers=headers)),expected)

    def test_private_loopback_and_invalid_addresses_never_unlock_overseas(self):
        for ip in ('127.0.0.1','192.168.1.1','::1','fe80::1','bad','203.0.113.1'):
            self.assertEqual(distribution.country(ip),'')

    def test_ipv4_mapped_ipv6_and_reader_error_are_safe(self):
        reader=Mock();reader.get.return_value={'country':{'iso_code':'CN'}}
        with patch.object(distribution,'_reader',reader),patch.object(distribution,'_next_stat',float('inf')):
            self.assertEqual(distribution.country('::ffff:114.114.114.114'),'CN')
            reader.get.assert_called_once_with('114.114.114.114')
            reader.get.return_value={'country':{'iso_code':'ZZ'}}
            self.assertEqual(distribution.country('8.8.8.8'),'')
            reader.get.side_effect=RuntimeError('bad database')
            self.assertEqual(distribution.country('8.8.8.8'),'')
