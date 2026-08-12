import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).with_name("briefing_manager.py")
UNIT_PATH = MODULE_PATH.parents[2] / "scripts" / "systemd" / "openclaw-briefing.service"


def load_module():
    redis_module = types.ModuleType("redis")
    redis_module.Redis = mock.Mock
    psycopg2_module = types.ModuleType("psycopg2")
    psycopg2_module.connect = mock.Mock
    spec = importlib.util.spec_from_file_location("briefing_manager", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    with mock.patch.dict(
        sys.modules,
        {"redis": redis_module, "psycopg2": psycopg2_module},
    ):
        spec.loader.exec_module(module)
    return module


class BriefingManagerTest(unittest.TestCase):
    def test_docker_mode_queries_without_database_password(self):
        module = load_module()
        module.USE_DOCKER = True
        rows = [
            {
                "agent_name": "WatchdogAgent",
                "category": "memory_status",
                "content": "healthy",
                "created_at": "2026-08-12T07:00:00-05:00",
            }
        ]

        with mock.patch.object(
            module.subprocess,
            "run",
            return_value=mock.Mock(stdout=json.dumps(rows)),
        ) as run:
            self.assertEqual(module.get_recent_memories(), rows)

        command = run.call_args.args[0]
        self.assertEqual(command[:3], ["docker", "exec", "postgres"])
        self.assertNotIn("OPENCLAW_DB_PASSWORD", command)
        self.assertTrue(run.call_args.kwargs["check"])

    def test_source_contains_no_literal_password(self):
        source = MODULE_PATH.read_text(encoding="utf-8")
        self.assertNotIn('"password": "', source)
        self.assertNotIn("'password': '", source)

    def test_systemd_service_uses_docker_database_mode(self):
        unit = UNIT_PATH.read_text(encoding="utf-8")
        self.assertIn("Environment=OPENCLAW_DB_VIA_DOCKER=1", unit)
        self.assertIn("Environment=OPENCLAW_DB_CONTAINER=postgres", unit)
        self.assertNotIn("OPENCLAW_DB_PASSWORD=", unit)


if __name__ == "__main__":
    unittest.main()
