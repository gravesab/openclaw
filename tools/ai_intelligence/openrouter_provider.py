"""HTTP provider implementation for the OpenRouter cloud fallback."""

from __future__ import annotations

import json
import socket
from time import perf_counter
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from tools.ai_intelligence.execution_models import (
    ProviderRequest,
    ProviderResponse,
)
from tools.ai_intelligence.openrouter_config import (
    OpenRouterConfig,
    OpenRouterConfigurationError,
    is_openrouter_model_id,
    to_openrouter_model_name,
)
from tools.ai_intelligence.provider import (
    AIProvider,
    InvalidProviderResponseError,
    ProviderTimeoutError,
    ProviderUnavailableError,
)

_RESERVED_PARAMETERS = frozenset({"model", "messages", "stream"})


class OpenRouterProvider:
    """Execute model requests through OpenRouter's OpenAI-compatible API."""

    def __init__(
        self,
        config: OpenRouterConfig | None = None,
    ) -> None:
        self._config = config or OpenRouterConfig.from_env()

    @property
    def name(self) -> str:
        return "openrouter"

    def supports_model(self, model_id: str) -> bool:
        if not is_openrouter_model_id(model_id):
            return False

        try:
            to_openrouter_model_name(model_id)
        except OpenRouterConfigurationError:
            return False

        return True

    def is_available(self) -> bool:
        """Return whether a key is configured (no network probe)."""

        return bool(self._config.api_key.strip())

    def execute(
        self,
        request: ProviderRequest,
    ) -> ProviderResponse:
        if not self.supports_model(request.model_id):
            raise ProviderUnavailableError(
                f"OpenRouter does not support model ID: "
                f"{request.model_id}"
            )

        model_name = to_openrouter_model_name(request.model_id)
        timeout = (
            request.timeout_seconds
            or self._config.default_timeout_seconds
        )

        messages: list[dict[str, str]] = []
        if request.system_prompt:
            messages.append(
                {"role": "system", "content": request.system_prompt}
            )
        messages.append({"role": "user", "content": request.prompt})

        payload: dict[str, Any] = {
            "model": model_name,
            "messages": messages,
            "stream": False,
        }
        for key, value in dict(request.parameters).items():
            if key not in _RESERVED_PARAMETERS:
                payload[key] = value

        http_request = Request(
            url=f"{self._config.base_url}/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Authorization": f"Bearer {self._config.api_key}",
            },
            method="POST",
        )

        started = perf_counter()

        try:
            with urlopen(http_request, timeout=timeout) as response:
                raw_body = response.read()
        except (TimeoutError, socket.timeout) as exc:
            raise ProviderTimeoutError(
                f"OpenRouter request timed out after "
                f"{timeout} seconds"
            ) from exc
        except HTTPError as exc:
            if exc.code in (401, 403):
                raise ProviderUnavailableError(
                    "OpenRouter rejected the API key"
                ) from exc
            raise ProviderUnavailableError(
                f"OpenRouter returned HTTP {exc.code}"
            ) from exc
        except URLError as exc:
            if isinstance(exc.reason, socket.timeout):
                raise ProviderTimeoutError(
                    f"OpenRouter request timed out after "
                    f"{timeout} seconds"
                ) from exc
            raise ProviderUnavailableError(
                f"OpenRouter is unavailable: {exc.reason}"
            ) from exc
        except OSError as exc:
            raise ProviderUnavailableError(
                f"OpenRouter connection failed: {exc}"
            ) from exc

        duration_ms = max(
            0,
            round((perf_counter() - started) * 1000),
        )

        content = self._parse_content(raw_body)

        return ProviderResponse(
            provider_name=self.name,
            model_id=request.model_id,
            content=content,
            duration_ms=duration_ms,
            raw_response=self._parse_json(raw_body),
        )

    @staticmethod
    def _parse_json(raw_body: bytes) -> dict[str, Any]:
        try:
            parsed = json.loads(raw_body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise InvalidProviderResponseError(
                "OpenRouter returned invalid JSON"
            ) from exc
        if not isinstance(parsed, dict):
            raise InvalidProviderResponseError(
                "OpenRouter response must be a JSON object"
            )
        return parsed

    @classmethod
    def _parse_content(cls, raw_body: bytes) -> str:
        parsed = cls._parse_json(raw_body)
        choices = parsed.get("choices")
        if not isinstance(choices, list) or not choices:
            raise InvalidProviderResponseError(
                "OpenRouter response has no choices"
            )
        first = choices[0]
        message = first.get("message") if isinstance(
            first, dict
        ) else None
        content = message.get("content") if isinstance(
            message, dict
        ) else None
        if not isinstance(content, str) or not content.strip():
            raise InvalidProviderResponseError(
                "OpenRouter returned blank text content"
            )
        return content


def build_openrouter_provider() -> AIProvider:
    """Build an OpenRouter provider from environment configuration."""

    return OpenRouterProvider()
