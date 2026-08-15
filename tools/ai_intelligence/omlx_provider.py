"""OpenAI-compatible HTTP provider implementation for oMLX."""

from __future__ import annotations

import json
import socket
from time import perf_counter
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from tools.ai_intelligence.execution_models import ProviderRequest, ProviderResponse
from tools.ai_intelligence.omlx_config import (
    OMLXConfig,
    OMLXConfigurationError,
    is_omlx_model_id,
    to_omlx_model_name,
)
from tools.ai_intelligence.provider import (
    AIProvider,
    InvalidProviderResponseError,
    ProviderTimeoutError,
    ProviderUnavailableError,
)

RESERVED_PARAMETERS = frozenset({"model", "messages", "stream"})


class OMLXProvider:
    """Execute model requests through the M4 oMLX HTTP API."""

    def __init__(self, config: OMLXConfig | None = None) -> None:
        self._config = config or OMLXConfig.from_env()

    @property
    def name(self) -> str:
        return "omlx"

    def supports_model(self, model_id: str) -> bool:
        if not is_omlx_model_id(model_id):
            return False
        try:
            to_omlx_model_name(model_id)
        except OMLXConfigurationError:
            return False
        return True

    def execute(self, request: ProviderRequest) -> ProviderResponse:
        if not self.supports_model(request.model_id):
            raise ProviderUnavailableError(
                f"oMLX does not support model ID: {request.model_id}"
            )

        messages: list[dict[str, str]] = []
        if request.system_prompt:
            messages.append({"role": "system", "content": request.system_prompt})
        messages.append({"role": "user", "content": request.prompt})

        parameters = dict(request.parameters)
        forbidden = sorted(RESERVED_PARAMETERS & parameters.keys())
        if forbidden:
            raise InvalidProviderResponseError(
                "oMLX request parameters cannot override: "
                + ", ".join(forbidden)
            )

        payload: dict[str, Any] = {
            "model": to_omlx_model_name(request.model_id),
            "messages": messages,
            "stream": False,
        }
        payload.update(parameters)
        timeout = request.timeout_seconds or self._config.default_timeout_seconds
        http_request = Request(
            url=f"{self._config.base_url}/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self._config.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method="POST",
        )
        started = perf_counter()
        try:
            with urlopen(http_request, timeout=timeout) as response:
                raw_body = response.read()
        except (TimeoutError, socket.timeout) as exc:
            raise ProviderTimeoutError(
                f"oMLX request timed out after {timeout} seconds"
            ) from exc
        except HTTPError as exc:
            raise ProviderUnavailableError(
                f"oMLX returned HTTP {exc.code}"
            ) from exc
        except URLError as exc:
            if isinstance(exc.reason, socket.timeout):
                raise ProviderTimeoutError(
                    f"oMLX request timed out after {timeout} seconds"
                ) from exc
            raise ProviderUnavailableError(
                f"oMLX is unavailable: {exc.reason}"
            ) from exc
        except OSError as exc:
            raise ProviderUnavailableError(
                f"oMLX connection failed: {exc}"
            ) from exc

        parsed = self._parse_response(raw_body)
        return ProviderResponse(
            provider_name=self.name,
            model_id=request.model_id,
            content=parsed["choices"][0]["message"]["content"],
            duration_ms=max(0, round((perf_counter() - started) * 1000)),
            raw_response=parsed,
        )

    @staticmethod
    def _parse_response(raw_body: bytes) -> dict[str, Any]:
        try:
            parsed = json.loads(raw_body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise InvalidProviderResponseError(
                "oMLX returned invalid JSON"
            ) from exc
        if not isinstance(parsed, dict):
            raise InvalidProviderResponseError(
                "oMLX response must be a JSON object"
            )
        choices = parsed.get("choices")
        if not isinstance(choices, list) or not choices:
            raise InvalidProviderResponseError(
                "oMLX response is missing choices"
            )
        first = choices[0]
        message = first.get("message") if isinstance(first, dict) else None
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, str) or not content.strip():
            raise InvalidProviderResponseError(
                "oMLX response is missing text content"
            )
        return parsed


def build_omlx_provider() -> AIProvider:
    """Build an oMLX provider from environment configuration."""

    return OMLXProvider()
