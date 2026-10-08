"""Whole-catalog sorting and stable page boundaries, without remote collection."""
import tempfile
import threading
import unittest
from unittest.mock import patch
from server.hapstore import app, catalog_paging, collector, db


class CatalogSortTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old = db.DB_PATH
        db.DB_PATH = self.temp.name + '/store.db'
        db._local = threading.local(); db._initialized = False; db.init_db()
        catalog_paging._snapshots.clear()

    def tearDown(self):
        db.connect().close(); db.DB_PATH = self.old
        db._local = threading.local(); db._initialized = False
        catalog_paging._snapshots.clear(); self.temp.cleanup()

    def listing(self, n, stars=0, downloads=None, created=1, updated=1, category='工具'):
        id = db.upsert_app(f'owner/app{n}', stars=stars, category=category)
        db.replace_releases(id, [dict(tag='v1', github_downloads=downloads, assets=[])])
        db.connect().execute('UPDATE app SET created_at=?,updated_at=? WHERE id=?', (created, updated, id))
        db.connect().commit()
        return id

    def ids(self, **kwargs):
        return [r['id'] for r in db.list_apps(**kwargs)['items']]

    def test_all_modes_reverse_globally_and_ties_use_id(self):
        a = self.listing(1, stars=100, downloads=40, created=30, updated=500)
        b = self.listing(2, stars=120, downloads=20, created=20, updated=10)
        c = self.listing(3, stars=120, downloads=20, created=20, updated=10)
        d = self.listing(4, stars=1000, downloads=0, created=10, updated=1)
        expected = {'discover': [d,c,b,a], 'stars': [d,c,b,a], 'downloads': [a,c,b,d], 'new': [a,c,b,d]}
        for sort, order in expected.items():
            pages = [db.list_apps(sort=sort, page=p, page_size=1)['items'][0]['id'] for p in range(1,5)]
            self.assertEqual(pages, order, sort)
            self.assertEqual(self.ids(sort=sort, direction='asc'), list(reversed(order)), sort)
        self.assertEqual(db.get_app(a)['created_at'], 30)

    def test_download_unknown_is_last_in_both_directions_and_counts_match_sources(self):
        a = self.listing(1, stars=90, downloads=5)
        b = self.listing(2, stars=110, downloads=20)
        unknown = self.listing(3)
        empty = db.upsert_app('owner/empty')
        source = self.listing(4, stars=40, downloads=25)
        db.connect().execute("UPDATE app SET status='hidden' WHERE id=?", (source,))
        db.connect().execute('INSERT INTO app_source VALUES (?,?,?,?)', (a,source,'[]',1)); db.connect().commit()
        self.assertEqual(self.ids(sort='stars')[0], a)
        self.assertEqual(self.ids(sort='downloads'), [a,b,empty,unknown])
        self.assertEqual(self.ids(sort='downloads',direction='asc'), [b,a,unknown,empty])
        self.assertEqual(db.list_apps(sort='downloads')['items'][0]['github_downloads'], 30)

    def test_snapshot_survives_count_changes_and_new_listings_without_duplicates(self):
        ids = [self.listing(n, stars=n) for n in range(6)]
        first = db.list_apps(sort='stars', page_size=2, pagination='snapshot')
        token = first['snapshot']
        db.connect().execute('UPDATE app SET stars=999 WHERE id=?', (ids[0],)); db.connect().commit()
        self.listing(99, stars=9999)
        result = first['items']
        for page in (2,3):
            result += db.list_apps(sort='stars',page=page,page_size=2,pagination='snapshot',snapshot=token)['items']
        self.assertEqual([r['id'] for r in result], list(reversed(ids)))
        self.assertEqual(db.list_apps(sort='stars',pagination='snapshot')['total'], 7)

    def test_hidden_listing_and_expired_or_wrong_scope_snapshot(self):
        ids = [self.listing(n) for n in range(4)]
        first = db.list_apps(sort='new', page_size=2, pagination='snapshot')
        token = first['snapshot']
        db.connect().execute("UPDATE app SET status='hidden' WHERE id=?", (ids[1],)); db.connect().commit()
        second = db.list_apps(sort='new',page=2,page_size=2,pagination='snapshot',snapshot=token)
        self.assertEqual([r['id'] for r in second['items']], [ids[0]])
        self.assertTrue(db.list_apps(sort='new',direction='asc',page_size=2,pagination='snapshot',snapshot=token)['snapshot_expired'])
        with patch.object(catalog_paging.time, 'monotonic', return_value=10**12):
            self.assertTrue(db.list_apps(sort='new',page_size=2,pagination='snapshot',snapshot=token)['snapshot_expired'])

    def test_endpoint_filters_direction_and_no_collection(self):
        a = self.listing(1, downloads=1, category='影音')
        self.listing(2, downloads=100, category='工具')
        with patch.object(collector, 'fetch_releases', side_effect=AssertionError('remote collection forbidden')):
            result = app.h_list_apps(dict(sort=['downloads'],direction=['asc'],category=['影音'],q=['app'],pagination=['snapshot']))
            self.assertEqual([r['id'] for r in result['items']], [a])
        # Arbitrary direction input cannot become SQL.
        self.assertEqual(self.ids(sort='new',direction="ASC; DROP TABLE app"), self.ids(sort='new'))

    def test_snapshot_cache_is_bounded_and_equivalent_order_reuses_token(self):
        token = catalog_paging.remember(('one',), [1,2])
        self.assertEqual(catalog_paging.remember(('one',), [1,2]), token)
        for i in range(catalog_paging.MAX_SNAPSHOTS + 10):
            catalog_paging.remember((i,), [1,2,3])
        self.assertLessEqual(len(catalog_paging._snapshots), catalog_paging.MAX_SNAPSHOTS)
        self.assertIsNone(catalog_paging.recall(token, ('one',)))


if __name__ == '__main__':
    unittest.main()
