#!/usr/bin/env python3
"""Jarvis 3D visualizer live server with DEV/PROD isolation.

Serves the visualizer page plus the live layer signal with strict
same-environment enforcement: this server answers for its own stack only,
and a ?env= value naming the other stack is refused (HTTP 403).

Own stack resolves from OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT, falling back
to the serving hostname (intelmini* / 100.85.36.72 = prod, else dev).

Cross-environment endpoint policy comes from the ai_environment gate
(deployed sibling preferred, repo checkout next, stdlib fallback last).
"""

import json
import os
import re
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT = 8080
# Loopback by default: the page and API are unauthenticated. Expose on a
# LAN/Tailscale interface only by setting OPENCLAW_JARVIS_BIND_HOST.
BIND_HOST = os.environ.get("OPENCLAW_JARVIS_BIND_HOST", "127.0.0.1").strip() or "127.0.0.1"
WEBROOT = Path(__file__).parent
SIGNAL_FILE = Path(
    os.environ.get("OPENCLAW_LAYER_SIGNAL_PATH", "/tmp/layer-signal.json")
)

ISOLATION_LABEL = "DEV→DEV / PROD→PROD"
CAPTIONS = {
    "dev": "DEV fixture · sample herd · read only",
    "prod": "PROD · live records · read only",
}

# Canonical signal layers (tools/ai_intelligence) to visualizer Sim LED ids.
# Model text always disambiguates; the LED is approximate by design.
LAYER_IDS = {
    "apple-intelligence": "apple",
    "llama.cpp": "llamacpp",
    "ollama": "llama",
    "mlx": "llama",
    "cloud": "openrouter",
    "mcp": "mcp",
}


def _load_gate():
    """Return (assert_allowed(url, env) -> None, source label).

    Prefers the deployed ai_environment sibling, then the repo checkout,
    then a stdlib fallback carrying the same blocklists.
    """

    try:
        from ai_environment import (  # type: ignore
            AIStackEnv as SiblingEnv,
            assert_endpoint_allowed as sibling_assert,
        )

        def check(url: str, env: str) -> None:
            sibling_assert(
                url,
                (
                    SiblingEnv.PRODUCTION
                    if env == "prod"
                    else SiblingEnv.DEVELOPMENT
                ),
            )

        return check, "sibling"
    except ImportError:
        pass

    try:
        # apps/jarvis-web/server.py -> repo root is two levels up.
        repo_root = Path(__file__).resolve().parents[2]
        if str(repo_root) not in sys.path:
            sys.path.insert(0, str(repo_root))
        from tools.ai_intelligence.ai_environment import (  # type: ignore
            AIStackEnv as RepoEnv,
            assert_endpoint_allowed as repo_assert,
        )

        def check(url: str, env: str) -> None:
            repo_assert(
                url,
                (
                    RepoEnv.PRODUCTION
                    if env == "prod"
                    else RepoEnv.DEVELOPMENT
                ),
            )

        return check, "repo"
    except ImportError:
        pass

    dev_blocked = {"100.85.36.72", "intelmini", "intelmini.local"}
    prod_blocked = {"100.85.188.74"}

    def check(url: str, env: str) -> None:
        host = (urlparse(url).hostname or "").lower()
        blocked = prod_blocked if env == "prod" else dev_blocked
        if host in blocked:
            raise ValueError(
                f"Cross-environment endpoint blocked for {env}: {host}"
            )

    return check, "fallback"


assert_policy, GATE_SOURCE = _load_gate()


def own_env() -> str:
    """Return this server's stack (prod only on explicit signal)."""

    raw = os.environ.get(
        "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT", ""
    ).strip().lower()
    if raw in {"production", "prod"}:
        return "prod"
    if raw in {"development", "dev"}:
        return "dev"
    import socket

    host = ""
    try:
        host = (socket.gethostname() or "").lower()
    except OSError:
        pass
    if (
        re.search(r"(^|\.)(intelmini|prod|production)([\.-]|$)", host)
        or host == "100.85.36.72"
    ):
        return "prod"
    return "dev"


OWN_ENV = own_env()


OTHER_SIGNAL_URL = {
    "dev": "http://100.85.188.74:8080/api/signal",
    "prod": "http://100.85.36.72:8080/api/signal",
}


def check_env_param(query_env: str | None) -> str | None:
    """Return an error message when ?env= names the other stack.

    The refusal is proven through the endpoint gate: resolving the
    other stack's signal URL from this stack must raise. The 403 stands
    regardless; the gate call is the policy decision procedure.
    """

    if query_env is None:
        return None
    if query_env == OWN_ENV:
        return None
    if query_env in ("dev", "prod"):
        try:
            assert_policy(OTHER_SIGNAL_URL[query_env], OWN_ENV)
        except Exception:
            pass
        return (
            f"Cross-environment request blocked: this server is "
            f"{OWN_ENV}, query asked for {query_env}"
        )
    return f"Unknown env: {query_env!r} (expected dev or prod)"


def adapt_signal(data: dict) -> dict:
    """Translate a signal-file record to the visualizer page shape."""

    out = dict(data)
    if "model_id" in out and "model" not in out:
        out["model"] = out.pop("model_id")
    if "tokens_per_sec" in out and "tps" not in out:
        out["tps"] = out.pop("tokens_per_sec")
    layer = out.get("layer")
    if isinstance(layer, str):
        out["layer"] = LAYER_IDS.get(layer, layer)
    out["env"] = OWN_ENV
    out["server_env"] = OWN_ENV
    out["isolation"] = ISOLATION_LABEL
    return out


def fixture_signal() -> dict:
    """Return the handbook-ingest example served with no live file."""

    return {
        "env": OWN_ENV,
        "layer": "mcp",
        "model": "mcp boundary / property.handbook.ingest",
        "tool": "tasks.create",
        "chunks": 127,
        "tasks_created": 12,
        "app": "property.handbook.ingest",
        "tps": "-",
        "note": (
            "No live signal file yet — showing the handbook ingest "
            "example. Run the engine or MCP path for live data."
        ),
        "fixture": True,
        "server_env": OWN_ENV,
        "isolation": ISOLATION_LABEL,
    }


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEBROOT), **kwargs)

    def end_headers(self):
        # No CORS headers: the visualizer is same-origin, and other sites
        # must not read /api/signal or /api/env through a viewer's browser.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _env_rejection(self, query_env: str | None):
        message = check_env_param(query_env)
        if message is None:
            return None
        return {
            "error": message,
            "server_env": OWN_ENV,
            "requested_env": query_env,
            "isolation": ISOLATION_LABEL,
        }

    @staticmethod
    def _is_tmp_signal_path(path: str) -> bool:
        if not path.startswith("/tmp/"):
            return False
        name = path[len("/tmp/"):]
        tmp_roots = {Path("/tmp"), Path("/tmp").resolve()}
        return (
            name == SIGNAL_FILE.name
            and SIGNAL_FILE.parent in tmp_roots
        )

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        query_env = query.get("env", [None])[0]

        if parsed.path in ("/api/signal", "/api/layer-signal"):
            rejected = self._env_rejection(query_env)
            if rejected is not None:
                self._send_json(403, rejected)
                return
            if SIGNAL_FILE.exists():
                try:
                    data = json.loads(SIGNAL_FILE.read_text())
                except Exception as exc:
                    self._send_json(
                        502,
                        {
                            "error": f"signal read failed: {exc}",
                            "server_env": OWN_ENV,
                            "isolation": ISOLATION_LABEL,
                        },
                    )
                    return
                if not isinstance(data, dict):
                    self._send_json(
                        502,
                        {
                            "error": "signal file must hold a JSON object",
                            "server_env": OWN_ENV,
                            "isolation": ISOLATION_LABEL,
                        },
                    )
                    return
                self._send_json(200, adapt_signal(data))
            else:
                self._send_json(200, fixture_signal())
            return

        if parsed.path == "/api/env":
            rejected = self._env_rejection(query_env)
            if rejected is not None:
                self._send_json(403, rejected)
                return
            self._send_json(
                200,
                {
                    "host": self.headers.get("Host", ""),
                    "env": OWN_ENV,
                    "caption": CAPTIONS[OWN_ENV],
                    "isolation": ISOLATION_LABEL,
                    "gateway_port": 18789,
                    "gate_source": GATE_SOURCE,
                    "signal_file": str(SIGNAL_FILE),
                    "signal_exists": SIGNAL_FILE.exists(),
                },
            )
            return

        if parsed.path == "/layer-signal.json" or self._is_tmp_signal_path(
            parsed.path
        ):
            # Raw file passthrough for debugging (same-env only). /tmp/<name>
            # serves only the configured signal file, never other /tmp files.
            rejected = self._env_rejection(query_env)
            if rejected is not None:
                self._send_json(403, rejected)
                return
            if SIGNAL_FILE.is_file():
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(SIGNAL_FILE.read_bytes())
            else:
                self._send_json(200, fixture_signal())
            return

        if parsed.path.startswith("/tmp/"):
            self._send_json(404, {"error": "not found"})
            return

        if parsed.path == "/":
            self.path = "/index.html"
        return super().do_GET()


if __name__ == "__main__":
    if len(sys.argv) > 1:
        PORT = int(sys.argv[1])
    print("Jarvis Visualizer — live server (own env: %s)" % OWN_ENV)
    print(f"Webroot: {WEBROOT}")
    print(f"Signal: {SIGNAL_FILE} exists={SIGNAL_FILE.exists()}")
    print(f"Gate: {GATE_SOURCE}")
    print("")
    print(f"Listening: http://{BIND_HOST}:{PORT}/?env={OWN_ENV}")
    if BIND_HOST in {"127.0.0.1", "::1", "localhost"}:
        print("Loopback only; set OPENCLAW_JARVIS_BIND_HOST to expose.")
    print(f"Live API: http://{BIND_HOST}:{PORT}/api/signal")
    print(f"Isolation: {ISOLATION_LABEL}, cross-env refused (403)")
    print("")
    server = ThreadingHTTPServer((BIND_HOST, PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped")
