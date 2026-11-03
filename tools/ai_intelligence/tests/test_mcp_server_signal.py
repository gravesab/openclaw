"""Tests for the MCP boundary layer-signal hook."""

from __future__ import annotations

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

# This environment's mcp package has no mcp.server submodule (the same gap
# behind the pre-existing test_mcp_boundary load error). Stub the small SDK
# surface so these tests exercise the hook lines, not the SDK.
if "mcp.server" not in sys.modules:
    try:
        import mcp.server  # noqa: F401
    except ImportError:
        _fake_server_module = types.ModuleType("mcp.server")

        class _FakeMCPServer:
            def __init__(self, *args: object, **kwargs: object) -> None:
                pass

            def tool(self, *args: object, **kwargs: object):
                def decorate(fn):
                    return fn

                return decorate

        _fake_server_module.MCPServer = _FakeMCPServer
        sys.modules["mcp.server"] = _fake_server_module

from tools.ai_intelligence.mcp_server import record_mcp_layer_signal


def stub_result(succeeded: bool = True):
    return SimpleNamespace(
        succeeded=succeeded,
        request_id="req-mcp-1",
        attempts=[
            SimpleNamespace(duration_ms=100),
            SimpleNamespace(duration_ms=250),
        ],
    )


class RecordMcpLayerSignalTests(unittest.TestCase):
    def test_writes_boundary_record(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "layer-signal.json")
            with patch.dict(
                "os.environ", {"OPENCLAW_LAYER_SIGNAL_PATH": path}
            ):
                record_mcp_layer_signal(
                    "finance.categorize", stub_result()
                )
            loaded = json.loads(Path(path).read_text("utf-8"))

        self.assertEqual(loaded["layer"], "mcp")
        self.assertEqual(
            loaded["model"], "mcp boundary / finance.categorize"
        )
        self.assertEqual(loaded["latency_ms"], 350)
        self.assertTrue(loaded["ok"])
        self.assertEqual(loaded["request_id"], "req-mcp-1")

    def test_names_actual_component(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "layer-signal.json")
            with patch.dict(
                "os.environ", {"OPENCLAW_LAYER_SIGNAL_PATH": path}
            ):
                record_mcp_layer_signal(
                    "ranchbrain", stub_result(succeeded=False)
                )
            loaded = json.loads(Path(path).read_text("utf-8"))

        self.assertEqual(loaded["model"], "mcp boundary / ranchbrain")
        self.assertFalse(loaded["ok"])

    def test_write_failure_never_raises(self) -> None:
        with patch(
            "tools.ai_intelligence.mcp_server.write_mcp_layer_signal",
            side_effect=OSError("disk gone"),
        ):
            record_mcp_layer_signal("ranchbrain", stub_result())


class ExecuteMcpRequestWiringTests(unittest.TestCase):
    def test_execution_records_boundary_layer(self) -> None:
        from tools.ai_intelligence.mcp_server import execute_mcp_request

        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "layer-signal.json")
            with (
                patch(
                    "tools.ai_intelligence.mcp_server"
                    ".require_dev_mcp_environment"
                ),
                patch(
                    "tools.ai_intelligence.mcp_server"
                    ".parse_mcp_execution_request",
                    return_value=SimpleNamespace(
                        component_id="finance.categorize",
                        prompt="categorize",
                        system_prompt=None,
                        timeout_seconds=60.0,
                    ),
                ),
                patch(
                    "tools.ai_intelligence.mcp_server"
                    ".build_execution_engine_from_environment"
                ) as build_engine,
                patch.dict(
                    "os.environ",
                    {"OPENCLAW_LAYER_SIGNAL_PATH": path},
                ),
            ):
                fake_result = SimpleNamespace(
                    request_id="req-x",
                    component_id="finance.categorize",
                    status=SimpleNamespace(value="success"),
                    content="done",
                    selected_model_id="m",
                    attempts=[],
                    succeeded=True,
                )
                build_engine.return_value.execute.return_value = (
                    fake_result
                )
                execute_mcp_request("finance.categorize", "categorize")
            loaded = json.loads(Path(path).read_text("utf-8"))

        self.assertEqual(loaded["layer"], "mcp")
        self.assertEqual(
            loaded["model"], "mcp boundary / finance.categorize"
        )


if __name__ == "__main__":
    unittest.main()
