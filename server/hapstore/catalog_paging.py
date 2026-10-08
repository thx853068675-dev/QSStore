"""Bounded, short-lived ordering snapshots; no package files or remote reads."""
from __future__ import annotations
from collections import OrderedDict
import hashlib
import json
import threading
import time

TTL = 15 * 60
MAX_SNAPSHOTS = 64
MAX_IDS = 100_000
_lock = threading.Lock()
_snapshots = OrderedDict()


def remember(key: tuple, ids: list[int]) -> str:
    token = hashlib.sha256(json.dumps([key, ids], separators=(',', ':')).encode()).hexdigest()[:32]
    now = time.monotonic()
    with _lock:
        for expired in [t for t, (_, _, end) in _snapshots.items() if end <= now]:
            del _snapshots[expired]
        _snapshots[token] = (key, tuple(ids), now + TTL)
        _snapshots.move_to_end(token)
        while len(_snapshots) > MAX_SNAPSHOTS or sum(len(row[1]) for row in _snapshots.values()) > MAX_IDS:
            _snapshots.popitem(last=False)
    return token


def recall(token: str, key: tuple) -> tuple[int, ...] | None:
    with _lock:
        row = _snapshots.get(token)
        if row is None or row[0] != key or row[2] <= time.monotonic():
            return None
        _snapshots.move_to_end(token)
        return row[1]
