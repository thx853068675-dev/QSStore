"""Account-scoped library, independent from geographic discovery visibility."""
from __future__ import annotations

import re
import time
from . import db

RELATIONS = (('app_follow','account_id'), ('update_push_watch','account_id'),
             ('personal_install','account_id'), ('publisher','account_id'))


def app_ids(account_id: str) -> set[int]:
    if not account_id:return set()
    conn=db.connect();ids=set()
    tables={row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for table,column in RELATIONS:
        if table in tables:
            ids.update(row[0] for row in conn.execute(f'SELECT DISTINCT app_id FROM {table} WHERE {column}=?',(account_id,)))
    return ids


def allows(account_id: str, app_id: int) -> bool:
    return bool(account_id) and app_id in app_ids(account_id)


def library(account_id: str) -> dict:
    items=[];ids=sorted(app_ids(account_id));conn=db.connect()
    for offset in range(0,len(ids),100):
        batch=ids[offset:offset+100]
        rows=conn.execute(f"SELECT * FROM app WHERE status='published' AND id IN ({','.join('?' for _ in batch)}) ORDER BY id",batch).fetchall()
        related=db._app_related(rows)
        items.extend(db._row_to_app(row,related=related) for row in rows)
    return dict(items=items)


def sync(account_id: str, body: dict) -> dict:
    if not account_id:raise ValueError('需要登录账号')
    client=body.get('client_id','legacy');items=body.get('items')
    if not isinstance(client,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,96}',client):raise ValueError('设备标识无效')
    if not isinstance(items,list) or len(items)>200:raise ValueError('应用清单格式不正确')
    parsed=[];seen=set()
    for item in items:
        if not isinstance(item,dict):raise ValueError('应用清单格式不正确')
        app_id=item.get('app_id',0);bundle=item.get('bundle_name');code=item.get('version_code')
        if type(app_id) is not int or app_id<0 or not isinstance(bundle,str) or not 0<len(bundle)<=255 or type(code) is not int or not 0<=code<2**63:
            raise ValueError('应用清单格式不正确')
        if (app_id,bundle) in seen:raise ValueError('应用清单中有重复项目')
        seen.add((app_id,bundle));parsed.append((app_id,bundle,code))
    conn=db.connect();bundles=list({bundle for _,bundle,code in parsed if code>0});known={}
    if bundles:
        for row in conn.execute(f'''SELECT DISTINCT b.bundle_name,b.catalog_app_id FROM catalog_asset b
            JOIN app a ON a.id=b.catalog_app_id WHERE a.status='published'
            AND b.bundle_name IN ({','.join('?' for _ in bundles)})''',bundles):
            known.setdefault(row['bundle_name'],set()).add(row['catalog_app_id'])
    accepted={}
    for app_id,bundle,code in parsed:
        matches=known.get(bundle,set())
        if not app_id and len(matches)==1:app_id=next(iter(matches))
        if code>0 and app_id in matches:accepted[(app_id,bundle)]=(account_id,client,app_id,bundle,code,int(time.time()))
    with conn:
        conn.execute('DELETE FROM personal_install WHERE account_id=? AND client_id=?',(account_id,client))
        conn.executemany('INSERT INTO personal_install(account_id,client_id,app_id,bundle_name,installed_code,updated_at) VALUES(?,?,?,?,?,?)',accepted.values())
    return library(account_id)
