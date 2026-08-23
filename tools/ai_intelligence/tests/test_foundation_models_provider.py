"""Tests for the Apple Foundation Models provider boundary."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.ai_intelligence.execution_models import ProviderRequest
from tools.ai_intelligence.foundation_models_config import (
    FoundationModelsConfig,
    FoundationModelsConfigurationError,
    is_foundation_models_configured,
)
from tools.ai_intelligence.foundation_models_provider import FoundationModelsProvider
from tools.ai_intelligence.provider import (
    AIProvider,
    InvalidProviderResponseError,
    ProviderTimeoutError,
    ProviderUnavailableError,
)


class FoundationModelsProviderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.provider = FoundationModelsProvider(
            FoundationModelsConfig(Path("/usr/local/bin/openclaw-foundation-models"), 30)
        )

    def test_implements_provider_contract(self) -> None:
        self.assertIsInstance(self.provider, AIProvider)
        self.assertEqual(self.provider.name, "apple-foundation-models")
        self.assertTrue(self.provider.supports_model("apple-foundation-models"))

    @patch("tools.ai_intelligence.foundation_models_provider.subprocess.run")
    def test_reports_helper_availability_without_prompt(self, run) -> None:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout='{"apiAvailable":true}', stderr=""
        )

        self.assertTrue(self.provider.is_available())
        sent = json.loads(run.call_args.kwargs["input"])
        self.assertEqual(sent, {"operation": "availability"})

    @patch("tools.ai_intelligence.foundation_models_provider.subprocess.run")
    def test_executes_private_text_through_helper(self, run) -> None:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout='{"content":"Private summary"}', stderr=""
        )

        response = self.provider.execute(
            ProviderRequest(
                model_id="apple-foundation-models",
                prompt="Summarize the local note.",
                system_prompt="Be concise.",
            )
        )

        self.assertEqual(response.content, "Private summary")
        sent = json.loads(run.call_args.kwargs["input"])
        self.assertEqual(sent["operation"], "execute")
        self.assertEqual(sent["prompt"], "Summarize the local note.")

    @patch("tools.ai_intelligence.foundation_models_provider.subprocess.run")
    def test_timeout_is_normalized(self, run) -> None:
        run.side_effect = subprocess.TimeoutExpired("helper", 30)
        with self.assertRaises(ProviderTimeoutError):
            self.provider.execute(
                ProviderRequest(
                    model_id="apple-foundation-models", prompt="Hello"
                )
            )

    @patch("tools.ai_intelligence.foundation_models_provider.subprocess.run")
    def test_helper_generation_error_is_unavailable_for_fallback(self, run) -> None:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout='{"error":"not ready"}', stderr=""
        )
        with self.assertRaises(ProviderUnavailableError):
            self.provider.execute(
                ProviderRequest(
                    model_id="apple-foundation-models", prompt="Hello"
                )
            )

    def test_rejects_uncontrolled_provider_parameters(self) -> None:
        with self.assertRaises(InvalidProviderResponseError):
            self.provider.execute(
                ProviderRequest(
                    model_id="apple-foundation-models",
                    prompt="Hello",
                    parameters={"temperature": 1},
                )
            )

    def test_configuration_requires_absolute_helper_path(self) -> None:
        with self.assertRaises(FoundationModelsConfigurationError):
            FoundationModelsConfig(Path("relative-helper"))

    @patch.dict("os.environ", {}, clear=True)
    def test_reports_unconfigured_without_helper_command(self) -> None:
        self.assertFalse(is_foundation_models_configured())

    @patch.dict(
        "os.environ",
        {
            "OPENCLAW_APPLE_FOUNDATION_MODELS_COMMAND": "/tmp/helper",
            "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "production",
        },
        clear=True,
    )
    def test_never_configures_provider_outside_development(self) -> None:
        self.assertFalse(is_foundation_models_configured())


if __name__ == "__main__":
    unittest.main()
