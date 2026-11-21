"""Atomically update the local DB-IP Country Lite database (CC BY 4.0)."""
from __future__ import annotations

from datetime import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.request
from zoneinfo import ZoneInfo


def update() -> dict:
    import maxminddb
    month = datetime.now(ZoneInfo('Asia/Shanghai')).strftime('%Y-%m')
    url = f'https://download.db-ip.com/free/dbip-country-lite-{month}.mmdb.gz'
    destination = Path(os.environ.get('HAPSTORE_GEOIP_DB', '/var/lib/hapstore/geoip/dbip-country-lite.mmdb'))
    destination.parent.mkdir(parents=True, exist_ok=True)
    manifest = destination.with_suffix('.json')
    try:
        previous = json.loads(manifest.read_text())
        if previous.get('month') == month and hashlib.sha256(destination.read_bytes()).hexdigest() == previous.get('sha256'):
            return dict(previous, cached=True)
    except (OSError, ValueError):
        pass
    fd, name = tempfile.mkstemp(prefix='.country-', dir=destination.parent)
    try:
        request = urllib.request.Request(url, headers={'User-Agent': 'QuietStart-GeoIP/1'})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with os.fdopen(fd, 'wb') as output:
            with opener.open(request, timeout=40) as response:
                if response.geturl().split('/', 3)[2] != 'download.db-ip.com':
                    raise ValueError('Unexpected GeoIP download origin')
                with gzip.GzipFile(fileobj=response) as archive:
                    length = 0
                    while chunk := archive.read(1024 * 1024):
                        length += len(chunk)
                        if length > 40 * 1024 * 1024:
                            raise ValueError('GeoIP database exceeds limit')
                        output.write(chunk)
        with maxminddb.open_database(name) as reader:
            metadata = reader.metadata()
            if 'country' not in metadata.database_type.lower() or metadata.node_count < 10000:
                raise ValueError('Unexpected GeoIP database')
            for ip in ('114.114.114.114','223.5.5.5'):
                if reader.get(ip)['country']['iso_code'] != 'CN':
                    raise ValueError('Country database validation failed')
            for ip in ('8.8.8.8','1.1.1.1'):
                if reader.get(ip)['country']['iso_code'] in ('CN',''):
                    raise ValueError('Country database validation failed')
        Path(name).chmod(0o644)
        digest = hashlib.sha256(Path(name).read_bytes()).hexdigest()
        os.replace(name, destination)
        result = dict(month=month, sha256=digest, bytes=length,
                      attribution='IP Geolocation by DB-IP', source='https://db-ip.com',
                      license='CC BY 4.0', license_url='https://creativecommons.org/licenses/by/4.0/')
        destination.with_suffix('.json').write_text(json.dumps(result, indent=2))
        return result
    finally:
        Path(name).unlink(missing_ok=True)


if __name__ == '__main__':
    print(json.dumps(update()))
