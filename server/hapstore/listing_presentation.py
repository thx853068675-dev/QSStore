"""Publisher-controlled catalog text and screenshot uploads."""
from __future__ import annotations

import base64
import hashlib
from io import BytesIO
import json
import re

from PIL import Image, UnidentifiedImageError

MAX_SCREENSHOTS = 6
MAX_IMAGE = 160 * 1024
MAX_BODY = 10240 * 1024
REF = re.compile(r'[a-f0-9]{24}')
SCHEMA = """
CREATE TABLE IF NOT EXISTS listing_presentation (
    app_id INTEGER PRIMARY KEY REFERENCES app(id) ON DELETE CASCADE,
    display_name TEXT,
    description TEXT
);
CREATE TABLE IF NOT EXISTS listing_screenshot (
    app_id INTEGER NOT NULL REFERENCES app(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    digest TEXT NOT NULL,
    data BLOB NOT NULL,
    PRIMARY KEY(app_id, position)
);
"""


def parse(body):
    values = body.get('presentation')
    if values is None:
        return {}
    if not isinstance(values, dict) or values.keys() - {'display_name', 'description', 'screenshots'}:
        raise ValueError('INVALID_PRESENTATION')
    result = {}
    for key, limit in [('display_name', 80), ('description', 2000)]:
        if key not in values:
            continue
        value = values[key]
        if not isinstance(value, str) or len(value.strip()) > limit or (key == 'display_name' and not value.strip()):
            raise ValueError('INVALID_PRESENTATION')
        result[key] = value.strip()
    if 'screenshots' in values:
        screenshots = values['screenshots']
        if not isinstance(screenshots, list) or len(screenshots) > MAX_SCREENSHOTS:
            raise ValueError('INVALID_SCREENSHOT')
        result['screenshots'] = [_screenshot(value) for value in screenshots]
    return result


def _screenshot(value):
    if not isinstance(value, str) or len(value) > 4 * ((MAX_IMAGE + 2) // 3):
        raise ValueError('INVALID_SCREENSHOT')
    if REF.fullmatch(value):
        return value, None
    try:
        data = base64.b64decode(value, validate=True)
        if not data or len(data) > MAX_IMAGE:
            raise ValueError
        with Image.open(BytesIO(data), formats=['JPEG']) as image:
            if not (1 <= image.width <= 1440 and 1 <= image.height <= 1440) or image.mode not in ('RGB', 'L'):
                raise ValueError
            image.load()
            # Re-encode only uploads carrying metadata. Client screenshots are already encoded from pixels.
            if set(image.info) - {'jfif', 'jfif_version', 'jfif_unit', 'jfif_density', 'progressive', 'progression'}:
                compressed = BytesIO()
                image.save(compressed, 'JPEG', quality=76, optimize=True)
                data = compressed.getvalue()
                if len(data) > MAX_IMAGE:
                    raise ValueError
    except (ValueError, OSError, UnidentifiedImageError, Image.DecompressionBombError) as exc:
        raise ValueError('INVALID_SCREENSHOT') from exc
    return hashlib.sha256(data).hexdigest()[:24], data


def apply(conn, app_id, values):
    if not values:
        return
    name = values.get('display_name')
    description = values.get('description')
    if name is not None or description is not None:
        conn.execute('''INSERT INTO listing_presentation(app_id,display_name,description) VALUES(?,?,?)
            ON CONFLICT(app_id) DO UPDATE SET display_name=COALESCE(excluded.display_name,listing_presentation.display_name),
            description=COALESCE(excluded.description,listing_presentation.description)''', (app_id, name, description))
        conn.execute('''UPDATE app SET display_name=COALESCE(?,display_name),description=COALESCE(?,description),
            summary=COALESCE(?,summary) WHERE id=?''',
                     (name, description, description[:120] if description is not None else None, app_id))
    if 'screenshots' in values:
        # Resolve retained images only against this listing, before replacing the gallery.
        old = {row['digest']: row['data'] for row in conn.execute(
            'SELECT digest,data FROM listing_screenshot WHERE app_id=?', (app_id,))}
        images = {}
        for digest, data in values['screenshots']:
            data = old.get(digest) if data is None else data
            if data is None:
                raise ValueError('INVALID_SCREENSHOT')
            images[digest] = data
        conn.execute('DELETE FROM listing_screenshot WHERE app_id=?', (app_id,))
        conn.executemany('INSERT INTO listing_screenshot VALUES(?,?,?,?)',
                         ((app_id, position, digest, data) for position, (digest, data) in enumerate(images.items())))


def preserve(conn, app_id, fields):
    row = conn.execute('SELECT * FROM listing_presentation WHERE app_id=?', (app_id,)).fetchone()
    if not row:
        return fields
    fields = dict(fields)
    if row['display_name'] is not None:
        fields['display_name'] = row['display_name']
    if row['description'] is not None:
        fields.update(description=row['description'], summary=row['description'][:120])
    return fields


def refs(conn, app_id):
    return [row['digest'] for row in conn.execute(
        'SELECT digest FROM listing_screenshot WHERE app_id=? ORDER BY position', (app_id,))]


def refs_for(conn, app_ids):
    if not app_ids:
        return {}
    placeholders = ','.join('?' for _ in app_ids)
    grouped = {}
    for row in conn.execute(f'''SELECT app_id,digest FROM listing_screenshot
        WHERE app_id IN ({placeholders}) ORDER BY app_id,position''', app_ids):
        grouped.setdefault(row['app_id'], []).append(row['digest'])
    return grouped


def configuration_revision(conn, app_id):
    row = conn.execute('''SELECT a.repo_full_name,a.display_name,a.description,a.category,p.account_id,s.repo_full_name
        FROM app a JOIN publisher p ON p.app_id=a.id
        LEFT JOIN app_source l ON l.app_id=a.id LEFT JOIN app s ON s.id=l.source_app_id
        WHERE a.id=? AND a.status='published' ''', (app_id,)).fetchone()
    if row is None:
        return ''
    snapshot = json.dumps([list(row), refs(conn, app_id)], ensure_ascii=False, separators=(',', ':'))
    return hashlib.sha256(snapshot.encode()).hexdigest()[:24]
