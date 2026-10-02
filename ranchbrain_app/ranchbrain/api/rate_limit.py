"""Per-tenant fixed-window rate limiter (DEV single-process, stdlib only).

Single-process in-memory buckets are the whole P3 deployment. A multi-worker
deployment needs a shared store (Redis/Postgres) — P3.1, noted wherever the
limiter is constructed. Thread-safe for ThreadingHTTPServer.
"""

from __future__ import annotations

import math
import threading
import time

WINDOW_SECONDS = 60


class RateLimiter:
    """Fixed windows keyed by (tenant_id, bucket class). No persistence."""

    def __init__(
        self,
        *,
        search_per_minute: int = 60,
        memory_per_minute: int = 120,
        time_fn=time.monotonic,
    ) -> None:
        self._limits = {
            "search": int(search_per_minute),
            "memory": int(memory_per_minute),
        }
        self._time_fn = time_fn
        self._lock = threading.Lock()
        self._counts: dict[tuple[str, str], list] = {}

    def limit_for(self, bucket_class: str) -> int:
        return self._limits[bucket_class]

    def _window(self, now: float) -> tuple[int, int]:
        start = int(now // WINDOW_SECONDS) * WINDOW_SECONDS
        return start, start + WINDOW_SECONDS

    def _reset_in(self, now: float, end: int) -> int:
        # Round up: a floored Retry-After lets clients retry inside the window.
        return max(1, math.ceil(end - now))

    def check(self, tenant_id: str, bucket_class: str) -> tuple[bool, int, int, int]:
        """Consume one token. Returns (allowed, remaining, reset_secs, limit)."""
        limit = self._limits[bucket_class]
        now = self._time_fn()
        start, end = self._window(now)
        key = (tenant_id, bucket_class)
        with self._lock:
            entry = self._counts.get(key)
            if entry is None or entry[0] != start:
                entry = [start, 0]
                self._counts[key] = entry
            if entry[1] < limit:
                entry[1] += 1
                return True, limit - entry[1], self._reset_in(now, end), limit
            return False, 0, self._reset_in(now, end), limit

    def peek(self, tenant_id: str, bucket_class: str) -> tuple[int, int, int]:
        """Current (remaining, reset_secs, limit) without consuming.

        Used so pre-limit responses (401/403/400) still carry headers.
        """
        limit = self._limits[bucket_class]
        now = self._time_fn()
        start, end = self._window(now)
        with self._lock:
            entry = self._counts.get((tenant_id, bucket_class))
            used = entry[1] if entry is not None and entry[0] == start else 0
        return max(0, limit - used), self._reset_in(now, end), limit
