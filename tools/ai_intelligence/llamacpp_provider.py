"""HTTP provider implementation for a local llama.cpp server."""

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
from tools.ai_intelligence.llamacpp_config import (
    LlamaCppConfig,
    LlamaCppConfigurationError,
    is_llamacpp_model_id,
    to_llamacpp_model_name,
)
from tools.ai_intelligence.provider import (
    AIProvider,
    InvalidProviderResponseError,
    ProviderTimeoutError,
    ProviderUnavailableError,
)

_RESERVED_PARAMETERS = frozenset({"model", "messages", "stream"})
_AVAILABILITY_TIMEOUT_SECONDS = 5.0


class LlamaCppProvider:
    """Execute model requests through llama-server's OpenAI-compatible API."""

    def __init__(
        self,
        config: LlamaCppConfig | None = None,
    ) -> None:
        self._config = config or LlamaCppConfig.from_env()

    @property
    def name(self) -> str:
        return "llama.cpp"

    @property
    def base_url(self) -> str:
        """Return the configured llama-server base URL (for status)."""

        return self._config.base_url

    def supports_model(self, model_id: str) -> bool:
        if not is_llamacpp_model_id(model_id):
            return False

        try:
            to_llamacpp_model_name(model_id)
        except LlamaCppConfigurationError:
            return False

        return True

    def is_available(self) -> bool:
        """Probe /health without sending caller content."""

        try:
            with urlopen(
                f"{self._config.base_url}/health",
                timeout=_AVAILABILITY_TIMEOUT_SECONDS,
            ) as response:
                return response.status == 200
        except (OSError, URLError, TimeoutError, ValueError):
            return False

    def execute(
        self,
        request: ProviderRequest,
    ) -> ProviderResponse:
        if not self.supports_model(request.model_id):
            raise ProviderUnavailableError(
                f"llama.cpp does not support model ID: "
                f"{request.model_id}"
            )

        model_name = to_llamacpp_model_name(request.model_id)
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
            url=f"{self._config.base_url}/v1/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers={
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
                f"llama.cpp request timed out after "
                f"{timeout} seconds"
            ) from exc
        except HTTPError as exc:
            raise ProviderUnavailableError(
                f"llama.cpp returned HTTP {exc.code}"
            ) from exc
        except URLError as exc:
            if isinstance(exc.reason, socket.timeout):
                raise ProviderTimeoutError(
                    f"llama.cpp request timed out after "
                    f"{timeout} seconds"
                ) from exc
            raise ProviderUnavailableError(
                f"llama.cpp is unavailable: {exc.reason}"
            ) from exc
        except OSError as exc:
            raise ProviderUnavailableError(
                f"llama.cpp connection failed: {exc}"
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
                "llama.cpp returned invalid JSON"
            ) from exc
        if not isinstance(parsed, dict):
            raise InvalidProviderResponseError(
                "llama.cpp response must be a JSON object"
            )
        return parsed

    @classmethod
    def _parse_content(cls, raw_body: bytes) -> str:
        parsed = cls._parse_json(raw_body)
        choices = parsed.get("choices")
        if not isinstance(choices, list) or not choices:
            raise InvalidProviderResponseError(
                "llama.cpp response has no choices"
            )
        message = choices[0].get("message") if isinstance(
            choices[0], dict
        ) else None
        content = message.get("content") if isinstance(
            message, dict
        ) else None
        if not isinstance(content, str) or not content.strip():
            raise InvalidProviderResponseError(
                "llama.cpp returned blank text content"
            )
        return content


def build_llamacpp_provider() -> AIProvider:
    """Build a llama.cpp provider from environment configuration."""

    return LlamaCppProvider()
