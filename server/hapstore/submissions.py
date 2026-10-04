# Copyright QuietStart contributors. SPDX-License-Identifier: MIT
"""Fast listing discovery and a durable, bounded package enrichment worker."""
from __future__ import annotations

import copy
import threading
import time
from concurrent.futures import Future, TimeoutError
from typing import Any

from . import collector, db

# Keep ordinary client requests comfortably below their 20-second read timeout.
DISCOVERY_TIMEOUT = 5
SNAPSHOT_TTL = 300
_lock = threading.Lock()
_cache: dict[tuple[str, str], tuple[float, dict[str, Any]]] = {}
_inflight: dict[tuple[str, str], Future] = {}
_slots = threading.BoundedSemaphore(4)
_wake = threading.Event()
_worker_started = False


def repository_snapshot(repo: str, token: str = "") -> dict[str, Any]:
    key = (db.DB_PATH, repo.lower())
    with _lock:
        cached = _cache.get(key)
        if cached and cached[0] > time.time():
            return copy.deepcopy(cached[1])
        future = _inflight.get(key)
        owner = future is None
        if owner:
            future = Future()
            _inflight[key] = future
    if not owner:
        try:
            return copy.deepcopy(future.result(timeout=12))
        except TimeoutError as e:
            raise collector.CollectError("GitHub 检查暂时较慢，请稍后重试") from e
    acquired = _slots.acquire(blocking=False)
    try:
        if not acquired:
            raise collector.CollectError("仓库检查繁忙，请稍后重试")
        snapshot = db.cached_repository_snapshot(repo, SNAPSHOT_TTL)
        if snapshot is None:
            try:
                snapshot = {
                    "metadata": collector.fetch_app_metadata(repo, token=token, timeout=DISCOVERY_TIMEOUT),
                    "releases": collector.fetch_releases(repo, token=token, timeout=DISCOVERY_TIMEOUT),
                    "fetched_at": int(time.time()),
                }
            except collector.CollectError:
                # An upstream outage must not stop relisting a known package.
                snapshot = db.cached_repository_snapshot(repo, 6 * 3600)
                if snapshot is None:
                    raise
        snapshot["releases"].sort(key=lambda r: r.get("published_at", ""), reverse=True)
        with _lock:
            if len(_cache) >= 128:
                _cache.pop(next(iter(_cache)))
            _cache[key] = (time.time() + SNAPSHOT_TTL, copy.deepcopy(snapshot))
        future.set_result(snapshot)
        return copy.deepcopy(snapshot)
    except Exception as e:
        future.set_exception(e)
        raise
    finally:
        if acquired:
            _slots.release()
        with _lock:
            _inflight.pop(key, None)


def prepared_snapshot(repo: str, token: str = "") -> dict[str, Any]:
    snapshot = repository_snapshot(repo, token)
    db.reuse_asset_metadata(repo, snapshot["releases"])
    return snapshot


def process_prepare_one(token: str = '') -> bool:
    task = db.claim_archive_inspection()
    if not task: return False
    try:
        from .package_archive import inspect_snapshot
        prepared = __import__('json').loads(task['prepared_json'])
        snapshot = inspect_snapshot(prepared['snapshot'], token)
        candidate = next(r for r in snapshot['releases'] if r.get('assets'))
        if prepared.get('require_identity'):
            # Source association must inspect plain HAPs too. Filenames, GitHub
            # tags and user supplied bundle names are never identity evidence.
            collector.enrich_assets_with_hap_metadata([candidate], token=token, limit=1)
            candidate['assets'] = [a for a in candidate['assets'] if a.get('bundle_name') and
                a.get('version_code', 0)>0 and len(a.get('sha256', '')) == 64]
            if not candidate['assets']:
                raise collector.CollectError('子仓安装包的包名尚无法核验，请检查安装包后重试')
        prepared['choices'] = [dict(tag=candidate['tag'], **{k: a.get(k, '') for k in
            ('name', 'size', 'bundle_name', 'version_name', 'version_code', 'min_api', 'display_name', 'sha256')})
            for a in candidate['assets']]
        for release in snapshot['releases']:
            for asset in release['assets']: asset.pop('_icon', None)
        prepared['snapshot'] = snapshot
        prepared['inspection_status'] = 'ready'
        db.finish_archive_inspection(task['token'], prepared)
    except Exception as error:
        db.finish_archive_inspection(task['token'], None, str(error))
    return True


def process_one(token: str = "") -> bool:
    task = db.claim_catalog_task()
    if task is None:
        return False
    payload = task["payload"]
    try:
        info = collector.sync_app(payload["repo"], token=token,
            snapshot=payload["snapshot"], selection=payload["selection"],
            generation=task["generation"])
        print(f"catalog enrichment app={task['app_id']} applied={info['applied']}", flush=True)
    except Exception as e:
        db.fail_catalog_task(task["app_id"], task["generation"], str(e), getattr(e, "retry_after", 0))
        print(f"catalog enrichment retry app={task['app_id']}: {e}", flush=True)
    return True


def process_refresh_one(token: str = '') -> bool:
    task = db.claim_refresh()
    if not task:
        return False
    try:
        collector.sync_app(task['repo_full_name'], token=token)
        db.finish_refresh(task['app_id'])
    except Exception as error:
        db.finish_refresh(task['app_id'], str(error), getattr(error, 'retry_after', 0))
    return True


def queue_due(limit: int = 20, progress=None) -> dict[str, Any]:
    rows = db.apps_needing_sync(limit=limit, max_age_seconds=collector.sync_max_age_seconds())
    queued = sum(db.enqueue_refresh(row['id'], collector.sync_max_age_seconds())['queued'] for row in rows)
    if rows:
        wake_worker()
    return {'queued': queued, 'synced': 0, 'failed': 0, 'errors': []}


def wake_worker() -> None:
    _wake.set()


def start_worker(token: str = "") -> None:
    global _worker_started
    with _lock:
        if _worker_started:
            return
        _worker_started = True
    db.recover_catalog_tasks()
    with db.connect():
        db.connect().execute("UPDATE refresh_task SET status='pending' WHERE status='running'")
    conn = db.connect()
    conn.execute("UPDATE submit_draft SET inspection_state='pending' WHERE inspection_state='running'")
    conn.commit()

    def run() -> None:
        while True:
            try:
                # Give each class of work a turn; archive discovery cannot starve updates.
                prepared = process_prepare_one(token)
                enriched = process_one(token)
                refreshed = process_refresh_one(token)
                if prepared or enriched or refreshed:
                    continue
            except Exception as e:
                print(f"catalog worker error: {type(e).__name__}: {e}", flush=True)
                conn = getattr(db._local, "conn", None)
                if conn is not None:
                    conn.close()
                    del db._local.conn
            _wake.wait(5)
            _wake.clear()

    threading.Thread(target=run, name="catalog-enrichment", daemon=True).start()
