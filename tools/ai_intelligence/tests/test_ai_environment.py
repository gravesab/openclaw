"""Tests for stack-environment endpoint isolation."""

from __future__ import annotations

import unittest
from unittest.mock import patch

from tools.ai_intelligence.ai_environment import (
    AIEnvironmentError,
    AIStackEnv,
    assert_endpoint_allowed,
    blocked_hosts,
    is_endpoint_allowed,
    stack_env_from_env,
)


class StackEnvTests(unittest.TestCase):
    def test_defaults_to_development(self) -> None:
        with patch.dict("os.environ", {}, clear=False):
            import os

            os.environ.pop("OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT", None)
            self.assertIs(
                stack_env_from_env(), AIStackEnv.DEVELOPMENT
            )

    def test_parses_production_forms(self) -> None:
        for raw in ("production", "PRODUCTION", "prod", " Prod "):
            with patch.dict(
                "os.environ",
                {"OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": raw},
            ):
                self.assertIs(
                    stack_env_from_env(), AIStackEnv.PRODUCTION
                )

    def test_rejects_unknown_environment(self) -> None:
        with patch.dict(
            "os.environ",
            {"OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "staging"},
        ):
            with self.assertRaises(AIEnvironmentError):
                stack_env_from_env()


class BlocklistTests(unittest.TestCase):
    def test_dev_blocks_prod_infra(self) -> None:
        blocked = blocked_hosts(AIStackEnv.DEVELOPMENT)
        self.assertIn("100.85.36.72", blocked)
        self.assertIn("intelmini.local", blocked)

    def test_prod_blocks_dev_infra(self) -> None:
        blocked = blocked_hosts(AIStackEnv.PRODUCTION)
        self.assertIn("100.85.188.74", blocked)

    def test_blocklists_do_not_overlap(self) -> None:
        self.assertFalse(
            set(blocked_hosts(AIStackEnv.DEVELOPMENT))
            & set(blocked_hosts(AIStackEnv.PRODUCTION))
        )


class EndpointMatrixTests(unittest.TestCase):
    def test_loopback_allowed_both_stacks(self) -> None:
        for env in AIStackEnv:
            self.assertTrue(
                is_endpoint_allowed("http://127.0.0.1:11434", env)
            )
            self.assertTrue(
                is_endpoint_allowed("http://localhost:8088", env)
            )

    def test_private_and_local_allowed_both_stacks(self) -> None:
        for env in AIStackEnv:
            self.assertTrue(
                is_endpoint_allowed("http://192.168.50.10:8000", env)
            )
            # Tailscale fleet IPs are CGNAT, not RFC1918.
            self.assertTrue(
                is_endpoint_allowed("http://100.104.100.96:11434", env)
            )
            self.assertTrue(
                is_endpoint_allowed(
                    "http://Andrew-M4-Pro-2.local:5062", env
                )
            )

    def test_openrouter_allowed_both_stacks(self) -> None:
        for env in AIStackEnv:
            self.assertTrue(
                is_endpoint_allowed(
                    "https://openrouter.ai/api/v1", env
                )
            )

    def test_dev_cannot_reach_prod_infra(self) -> None:
        env = AIStackEnv.DEVELOPMENT
        self.assertFalse(
            is_endpoint_allowed("http://100.85.36.72:5062", env)
        )
        self.assertFalse(
            is_endpoint_allowed("ws://intelmini.local:18789", env)
        )
        with self.assertRaises(AIEnvironmentError):
            assert_endpoint_allowed("http://100.85.36.72:5062", env)

    def test_prod_cannot_reach_dev_infra(self) -> None:
        env = AIStackEnv.PRODUCTION
        self.assertFalse(
            is_endpoint_allowed("http://100.85.188.74:5062", env)
        )
        with self.assertRaises(AIEnvironmentError):
            assert_endpoint_allowed("http://100.85.188.74:5062", env)

    def test_each_stack_reaches_own_infra(self) -> None:
        self.assertTrue(
            is_endpoint_allowed(
                "http://100.85.188.74:5062", AIStackEnv.DEVELOPMENT
            )
        )
        self.assertTrue(
            is_endpoint_allowed(
                "http://100.85.36.72:5062", AIStackEnv.PRODUCTION
            )
        )

    def test_public_hosts_blocked(self) -> None:
        for env in AIStackEnv:
            self.assertFalse(
                is_endpoint_allowed("https://evil.example.com", env)
            )
            self.assertFalse(
                is_endpoint_allowed("notaurl", env)
            )


if __name__ == "__main__":
    unittest.main()
