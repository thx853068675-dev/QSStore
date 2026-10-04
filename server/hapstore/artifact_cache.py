"""Bounded cache of verified package metadata, never package bodies or credentials."""
from __future__ import annotations
import base64
import copy
import json
import re
import time
from . import db

REVISION = 1
MAX_ROW_BYTES = 4 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
FIELDS = ('bundle_name', 'version_code', 'version_name', 'min_api', 'display_name',
          '_module_name', '_entry', '_icon_checked', 'archive_entry',
          '_icon_status_revision', '_icon_retry_at', '_icon_attempts')


def key(digest, kind):
    return f'{REVISION}:{kind}:{digest}' if re.fullmatch(r'[0-9a-f]{64}', digest or '') else ''


def get(digest, kind):
    cache_key = key(digest, kind)
    if not cache_key or not db._initialized:
        return None
    row = db.connect().execute('SELECT payload FROM artifact_inspection WHERE cache_key=?', (cache_key,)).fetchone()
    if not row or len(row['payload']) > MAX_ROW_BYTES:
        return None
    try:
        rows = json.loads(row['payload'])
        if not isinstance(rows, list) or not 0 < len(rows) <= 32:
            return None
        for item in rows:
            if not isinstance(item, dict):
                return None
            icon = item.pop('_cached_icon', None)
            if icon:
                mime, encoded = icon
                data = base64.b64decode(encoded, validate=True)
                if mime not in ('image/png', 'image/jpeg', 'image/webp') or len(data) > 1024 * 1024:
                    return None
                item['_icon'] = (mime, data)
        return rows
    except (ValueError, TypeError, KeyError):
        return None


def put(digest, kind, rows):
    cache_key = key(digest, kind)
    if not cache_key or not db._initialized or not rows or len(rows) > 32:
        return
    clean = []
    for row in rows:
        if not row.get('bundle_name') or not row.get('version_code'):
            return
        item = {field: copy.deepcopy(row[field]) for field in FIELDS if field in row}
        icon = row.get('_icon')
        if icon and icon[0] in ('image/png', 'image/jpeg', 'image/webp') and len(icon[1]) <= 1024 * 1024:
            item['_cached_icon'] = [icon[0], base64.b64encode(icon[1]).decode('ascii')]
        clean.append(item)
    payload = json.dumps(clean, ensure_ascii=False)
    if len(payload.encode()) > MAX_ROW_BYTES:
        return
    c = db.connect()
    with c:
        c.execute('INSERT OR REPLACE INTO artifact_inspection(cache_key,payload,checked_at) VALUES (?,?,?)',
                  (cache_key, payload, int(time.time())))
        c.execute('DELETE FROM artifact_inspection WHERE cache_key IN (SELECT cache_key FROM artifact_inspection ORDER BY checked_at DESC LIMIT -1 OFFSET 512)')
        total = c.execute('SELECT coalesce(sum(length(cast(payload AS BLOB))),0) FROM artifact_inspection').fetchone()[0]
        if total > MAX_TOTAL_BYTES:
            for row in c.execute('SELECT cache_key,length(cast(payload AS BLOB)) AS bytes FROM artifact_inspection ORDER BY checked_at').fetchall():
                c.execute('DELETE FROM artifact_inspection WHERE cache_key=?', (row['cache_key'],))
                total -= row['bytes']
                if total <= MAX_TOTAL_BYTES:
                    break
