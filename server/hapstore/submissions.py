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
        db.fail_catalog_task(task["app_id"], task["generation"], str(e))
        print(f"catalog enrichment retry app={task['app_id']}: {e}", flush=True)
    return True


def wake_worker() -> None:
    _wake.set()


def start_worker(token: str = "") -> None:
    global _worker_started
    with _lock:
        if _worker_started:
            return
        _worker_started = True
    db.recover_catalog_tasks()

    def run() -> None:
        while True:
            try:
                if process_one(token):
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
