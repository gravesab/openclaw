"""Provider adapter for the local Apple Foundation Models helper."""

from __future__ import annotations

import json
import subprocess
from time import perf_counter
from typing import Any

from tools.ai_intelligence.execution_models import ProviderRequest, ProviderResponse
from tools.ai_intelligence.foundation_models_config import (
    FoundationModelsConfig,
    is_foundation_models_model_id,
)
from tools.ai_intelligence.provider import (
    AIProvider,
    InvalidProviderResponseError,
    ProviderTimeoutError,
    ProviderUnavailableError,
)


class FoundationModelsProvider:
    """Execute lightweight private requests through a local macOS helper."""

    def __init__(self, config: FoundationModelsConfig | None = None) -> None:
        self._config = config or FoundationModelsConfig.from_env()

    @property
    def name(self) -> str:
        return "apple-foundation-models"

    def supports_model(self, model_id: str) -> bool:
        return is_foundation_models_model_id(model_id)

    def is_available(self) -> bool:
        """Probe the helper without sending caller content."""

        try:
            response = self._invoke({"operation": "availability"}, timeout=5.0)
        except (ProviderTimeoutError, ProviderUnavailableError, InvalidProviderResponseError):
            return False
        return response.get("apiAvailable") is True

    def execute(self, request: ProviderRequest) -> ProviderResponse:
        if not self.supports_model(request.model_id):
            raise ProviderUnavailableError(
                "Apple Foundation Models does not support model ID: "
                f"{request.model_id}"
            )
        if request.parameters:
            raise InvalidProviderResponseError(
                "Apple Foundation Models does not accept provider parameters"
            )

        started = perf_counter()
        response = self._invoke(
            {
                "operation": "execute",
                "prompt": request.prompt,
                "systemPrompt": request.system_prompt,
            },
            timeout=request.timeout_seconds or self._config.default_timeout_seconds,
        )
        if isinstance(response.get("error"), str):
            raise ProviderUnavailableError(
                "Apple Foundation Models helper could not generate a response"
            )
        content = response.get("content")
        if not isinstance(content, str) or not content.strip():
            raise InvalidProviderResponseError(
                "Apple Foundation Models helper returned no text content"
            )
        return ProviderResponse(
            provider_name=self.name,
            model_id=request.model_id,
            content=content,
            duration_ms=max(0, round((perf_counter() - started) * 1000)),
            raw_response=response,
        )

    def _invoke(self, payload: dict[str, Any], *, timeout: float) -> dict[str, Any]:
        try:
            result = subprocess.run(
                [str(self._config.command)],
                input=json.dumps(payload),
                text=True,
                capture_output=True,
                check=False,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            raise ProviderTimeoutError(
                f"Apple Foundation Models helper timed out after {timeout} seconds"
            ) from exc
        except OSError as exc:
            raise ProviderUnavailableError(
                "Apple Foundation Models helper is unavailable"
            ) from exc

        if result.returncode != 0:
            raise ProviderUnavailableError(
                "Apple Foundation Models helper is unavailable"
            )
        try:
            parsed = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise InvalidProviderResponseError(
                "Apple Foundation Models helper returned invalid JSON"
            ) from exc
        if not isinstance(parsed, dict):
            raise InvalidProviderResponseError(
                "Apple Foundation Models helper response must be a JSON object"
            )
        return parsed


def build_foundation_models_provider() -> AIProvider:
    """Build the configured Apple Foundation Models provider."""

    return FoundationModelsProvider()
