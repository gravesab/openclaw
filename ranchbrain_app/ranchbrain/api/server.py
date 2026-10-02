"""RanchBrain P3 read-only HTTP service (stdlib only, DEV single-process).

Exposes P2-isolated reads: memory list/fetch + knowledge search. Every
request binds two server-side facts — a Google-OIDC VerifiedPrincipal and
an explicitly requested tenant — through TenantContextResolver. The JWT
never supplies tenant authority.

Non-goals: writes, graph endpoints, streaming, multi-worker limits, TLS
termination. Bind loopback + Tailscale only; DEV port default 5063.
"""

from __future__ import annotations

import json
import logging
import re
import sys
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from os.path import basename
from urllib.parse import parse_qs, unquote, urlparse

from ..identity_oidc import (
    GoogleOidcIdentityAdapter,
    OidcConfiguration,
    TokenSignatureVerifier,
)
from ..memory_store import list_memories
from ..profile_manager import PROFILES
from ..search_engine import search as index_search
from ..tenancy import (
    Capability,
    TenancyError,
    TenancyErrorCode,
    TenantContext,
    TenantContextResolver,
    VerifiedPrincipal,
)
from .membership import MembershipStore, MembershipStoreError
from .rate_limit import RateLimiter

log = logging.getLogger("ranchbrain.api")

MODULE_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
REQUEST_ID_RE = re.compile(r"[A-Za-z0-9._-]{1,128}")
DEFAULT_LIMIT = 25
MAX_LIMIT = 100
MAX_QUESTION_CHARS = 500
MAX_ID_CHARS = 128
MAX_FILTER_CHARS = 128
FETCH_SCAN_LIMIT = 10_000
SEARCH_BUDGET_SECONDS = 5.0
SEARCH_WORKERS = 4
STORE_RETRY_AFTER_SECONDS = 30


@dataclass(frozen=True)
class ServiceConfig:
    """All P3 knobs. `verifier` has no default: without a JOSE-backed
    TokenSignatureVerifier the adapter refuses every request (401)."""

    oidc: OidcConfiguration
    verifier: TokenSignatureVerifier
    memberships: MembershipStore
    host: str = "127.0.0.1"
    port: int = 5063
    search_per_minute: int = 60
    memory_per_minute: int = 120


class _HttpError(Exception):
    def __init__(self, status: int, code: str, message: str, retry_after: int | None = None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retry_after = retry_after


class _State:
    def __init__(self, config: ServiceConfig, time_fn=None) -> None:
        self.config = config
        self.adapter = GoogleOidcIdentityAdapter(config.oidc, config.verifier)
        self.limiter = RateLimiter(
            search_per_minute=config.search_per_minute,
            memory_per_minute=config.memory_per_minute,
            time_fn=time_fn or time.monotonic,
        )
        # Shared and bounded: an overrunning search keeps its worker until it
        # finishes, so a per-request `with` pool would block past the budget.
        self.search_pool = ThreadPoolExecutor(max_workers=SEARCH_WORKERS,
                                              thread_name_prefix="ranchbrain-search")


def _summary(memory) -> dict:
    return {
        "id": memory.id,
        "module": memory.module,
        "category": memory.category,
        "title": memory.title,
        "memory_type": memory.memory_type,
        "tags": list(memory.tags),
        "created_at": memory.created_at,
        "updated_at": memory.updated_at,
    }


def _detail(memory) -> dict:
    return {
        **_summary(memory),
        "body": memory.body,
        "references": [
            {"type": ref.type, "value": ref.value, "title": ref.title}
            for ref in (memory.references or [])
        ],
        "source_type": memory.source_type,
        "tenant_id": memory.tenant_id,
    }


def _hit(hit: dict) -> dict:
    return {
        "source": basename(hit.get("path", "")),
        "line": hit.get("line", 0),
        "text": hit.get("text", ""),
        "modified_at": hit.get("modified_at", ""),
        "indexed_at": hit.get("indexed_at", ""),
    }


def _match_route(path: str):
    """Returns (kind, args) or None. Kinds: list, fetch, search."""
    parts = path.split("/")
    if parts == ["", "v1", "memory", "list"]:
        return ("list", {})
    if len(parts) == 5 and parts[:4] == ["", "v1", "memory", "fetch"]:
        return ("fetch", {"raw_id": unquote(parts[4])})
    if len(parts) >= 5 and parts[:3] == ["", "v1", "search"]:
        return ("search", {"profile": unquote(parts[3]), "question": unquote("/".join(parts[4:]))})
    return None


class _Handler(BaseHTTPRequestHandler):
    state: _State  # set by create_server
    server_version = "RanchBrainP3/1.0"

    # -- entry points -------------------------------------------------

    def do_GET(self):  # noqa: N802 (stdlib handler naming)
        self._handle("GET")

    def do_POST(self):  # noqa: N802
        self._respond(405, {"code": "method_not_allowed", "message": "GET only",
                            "request_id": self._request_id()}, "memory", "",
                        extra={"Allow": "GET"})

    do_PUT = do_POST
    do_DELETE = do_POST
    do_PATCH = do_POST
    do_HEAD = do_POST
    do_OPTIONS = do_POST

    def log_message(self, format, *args):  # noqa: N802
        # The stdlib line carries the request path, which embeds search
        # questions and memory ids; the spec forbids logging paths.
        pass

    # -- pipeline -----------------------------------------------------

    def _request_id(self) -> str:
        supplied = self.headers.get("X-Request-ID", "").strip()
        if REQUEST_ID_RE.fullmatch(supplied):
            return supplied
        return str(uuid.uuid4())

    def _handle(self, method: str) -> None:
        route = _match_route(urlparse(self.path).path)
        request_id = self._request_id()
        bucket = "search" if route and route[0] == "search" else "memory"
        tenant_echo = self.headers.get("X-Ranch-Tenant", "").strip()
        try:
            if route is None:
                raise _HttpError(404, "not_found", "unknown endpoint")
            kind, args = route
            principal = self._authenticate()
            tenant_id = self._requested_tenant()
            tenant_echo = tenant_id
            self._resolve(principal, tenant_id)
            allowed, remaining, reset, limit = self.state.limiter.check(tenant_id, bucket)
            if not allowed:
                raise _HttpError(429, "rate_limited",
                                 "per-tenant quota exceeded; retry shortly",
                                 retry_after=reset)
            query = parse_qs(urlparse(self.path).query)
            if kind == "list":
                payload = self._do_list(tenant_id, query)
            elif kind == "fetch":
                payload = self._do_fetch(tenant_id, args["raw_id"])
            else:
                payload = self._do_search(tenant_id, args["profile"], args["question"], query)
            self._respond(200, payload, bucket, tenant_echo, request_id,
                          remaining=remaining, reset=reset, limit=limit)
            log.info("ok route=%s tenant=%s request=%s", kind, tenant_id, request_id)
        except _HttpError as error:
            # Peek is authoritative here: a failed check() already left the
            # bucket exhausted, so peek reports remaining=0 with the live reset.
            remaining, reset, limit = self.state.limiter.peek(tenant_echo, bucket)
            self._respond(error.status,
                          {"code": error.code, "message": error.message,
                           "request_id": request_id},
                          bucket, tenant_echo, request_id,
                          remaining=remaining, reset=reset, limit=limit,
                          retry_after=error.retry_after)
            log.info("err status=%s code=%s tenant=%s request=%s",
                     error.status, error.code, tenant_echo or "-", request_id)
        except MembershipStoreError as error:
            log.warning("membership store down request=%s err=%s", request_id, error)
            remaining, reset, limit = self.state.limiter.peek(tenant_echo, bucket)
            self._respond(503, {"code": "store_unavailable",
                                "message": "membership store unavailable; retry shortly",
                                "request_id": request_id},
                          bucket, tenant_echo, request_id,
                          remaining=remaining, reset=reset, limit=limit,
                          retry_after=STORE_RETRY_AFTER_SECONDS)
        except Exception:  # never a traceback to the client
            log.exception("unexpected failure request=%s", request_id)
            remaining, reset, limit = self.state.limiter.peek(tenant_echo, bucket)
            self._respond(500, {"code": "internal", "message": "unexpected failure",
                                "request_id": request_id},
                          bucket, tenant_echo, request_id,
                          remaining=remaining, reset=reset, limit=limit)

    # -- stages -------------------------------------------------------

    def _authenticate(self) -> VerifiedPrincipal:
        header = self.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme != "Bearer" or not token.strip():
            raise _HttpError(401, "oidc_missing", "Bearer OIDC token required")
        try:
            return self.state.adapter.verify(token.strip())
        except TenancyError as error:
            # Adapter messages are safe (no token, no claims echoed).
            raise _HttpError(401, "oidc_invalid", str(error)) from error

    def _requested_tenant(self) -> str:
        tenant = self.headers.get("X-Ranch-Tenant", "").strip()
        if not tenant:
            raise _HttpError(400, TenancyErrorCode.TENANT_CONTEXT_INVALID.value,
                             "X-Ranch-Tenant header is required")
        return tenant

    def _resolve(self, principal: VerifiedPrincipal, tenant_id: str) -> TenantContext:
        users, tenants, memberships = self.state.config.memberships.snapshot()
        resolver = TenantContextResolver(
            environment=self.state.config.oidc.environment,
            users=users, tenants=tenants, memberships=memberships)
        try:
            return resolver.resolve(principal=principal,
                                    requested_tenant_id=tenant_id,
                                    capability=Capability.MEMORY_READ)
        except TenancyError as error:
            if error.code == TenancyErrorCode.TENANT_NOT_AUTHORIZED:
                raise _HttpError(403, error.code.value,
                                 "no active membership in this tenant") from error
            if error.code == TenancyErrorCode.CAPABILITY_FORBIDDEN:
                raise _HttpError(403, error.code.value,
                                 "membership lacks memory.read") from error
            raise _HttpError(400, error.code.value, str(error)) from error

    # -- endpoints ----------------------------------------------------

    @staticmethod
    def _limit(query: dict) -> int:
        raw = query.get("limit", [str(DEFAULT_LIMIT)])[0]
        try:
            value = int(raw)
        except ValueError:
            raise _HttpError(400, "invalid_limit", "limit must be an integer") from None
        if value < 1:
            raise _HttpError(400, "invalid_limit", "limit must be >= 1") from None
        return min(value, MAX_LIMIT)

    @staticmethod
    def _filter(query: dict, name: str) -> str | None:
        values = query.get(name)
        if not values:
            return None
        value = values[0]
        if len(value) > MAX_FILTER_CHARS:
            raise _HttpError(400, f"invalid_{name}", f"{name} is too long") from None
        return value

    def _do_list(self, tenant_id: str, query: dict) -> dict:
        module = self._filter(query, "module")
        if module is not None and MODULE_RE.fullmatch(module) is None:
            # list_memories joins MEMORIES_DIR/module: reject before it does.
            raise _HttpError(400, "invalid_module",
                             "module must match [a-z0-9][a-z0-9_-]{0,63}") from None
        rows = list_memories(
            module=module,
            limit=self._limit(query),
            memory_type=self._filter(query, "memory_type"),
            category=self._filter(query, "category"),
            tag=self._filter(query, "tag"),
            tenant_id=tenant_id,
        )
        return {"tenant_id": tenant_id, "count": len(rows),
                "memories": [_summary(memory) for _, memory in rows]}

    def _do_fetch(self, tenant_id: str, raw_id: str) -> dict:
        memory_id = (raw_id or "").strip()
        if not memory_id or len(memory_id) > MAX_ID_CHARS:
            raise _HttpError(400, "invalid_id", "memory id is missing or too long") from None
        # Match find_memory_by_id visibility (archived memories excluded), but
        # resolve over every candidate so an exact id wins even when other ids
        # share it as a prefix.
        matches = [
            memory for path, memory in
            list_memories(limit=FETCH_SCAN_LIMIT, tenant_id=tenant_id)
            if "_archive" not in path.parts and memory.id.startswith(memory_id)
        ]
        exact = [memory for memory in matches if memory.id == memory_id]
        if exact:
            return _detail_with_tenant(exact[0], tenant_id)
        if not matches:
            raise _HttpError(404, "memory_not_found", "no such memory") from None
        if len(matches) > 1:
            raise _HttpError(409, "memory_id_ambiguous",
                             "id prefix matches multiple memories") from None
        return _detail_with_tenant(matches[0], tenant_id)

    def _do_search(self, tenant_id: str, profile: str, question: str, query: dict) -> dict:
        if profile not in PROFILES:
            raise _HttpError(400, "invalid_profile",
                             f"profile must be one of {sorted(PROFILES)}") from None
        if not question.strip():
            raise _HttpError(400, "invalid_question", "question is required") from None
        if len(question) > MAX_QUESTION_CHARS:
            raise _HttpError(400, "question_too_long",
                             f"question must be at most {MAX_QUESTION_CHARS} characters") from None
        limit = self._limit(query)
        future = self.state.search_pool.submit(index_search, question, limit, profile, tenant_id)
        try:
            hits, total = future.result(timeout=SEARCH_BUDGET_SECONDS)
        except FuturesTimeout:
            future.cancel()
            raise _HttpError(503, "index_unavailable",
                             "search index rebuild overran its budget",
                             retry_after=5) from None
        return {"tenant_id": tenant_id, "profile": profile, "total": total,
                "hits": [_hit(hit) for hit in hits]}

    # -- wire ---------------------------------------------------------

    def _respond(self, status: int, obj: dict, bucket: str, tenant_echo: str,
                 request_id: str | None = None, *, remaining: int | None = None,
                 reset: int | None = None, limit: int | None = None,
                 retry_after: int | None = None, extra: dict | None = None) -> None:
        request_id = request_id or self._request_id()
        if remaining is None or reset is None or limit is None:
            remaining, reset, limit = self.state.limiter.peek(tenant_echo, bucket)
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Request-ID", request_id)
        self.send_header("X-Ranch-Tenant", tenant_echo)
        self.send_header("RateLimit-Limit", str(limit))
        self.send_header("RateLimit-Remaining", str(remaining))
        self.send_header("RateLimit-Reset", str(reset))
        if retry_after is not None:
            self.send_header("Retry-After", str(retry_after))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        if status == 401:
            self.send_header("WWW-Authenticate", "Bearer")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


def _detail_with_tenant(memory, tenant_id: str) -> dict:
    detail = _detail(memory)
    detail["tenant_id"] = tenant_id
    return detail


class _Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, state: _State) -> None:
        super().__init__(address, handler)
        self._state = state

    def server_close(self) -> None:
        super().server_close()
        self._state.search_pool.shutdown(wait=False, cancel_futures=True)


def create_server(config: ServiceConfig, *, time_fn=None) -> ThreadingHTTPServer:
    """Build (not start) the P3 server. Caller runs serve_forever()."""
    if config.verifier is None:
        raise TenancyError("OIDC signature verifier is not configured")
    state = _State(config, time_fn=time_fn)

    class BoundHandler(_Handler):
        pass

    BoundHandler.state = state
    return _Server((config.host, config.port), BoundHandler, state)


def main() -> int:
    """Manual DEV entry point. Always fails closed until a verifier exists."""
    print("No TokenSignatureVerifier is configured in this build: refusing to start. "
          "Wire a JOSE-backed verifier (crypto dependency pending approval) and retry.",
          file=sys.stderr, flush=True)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
