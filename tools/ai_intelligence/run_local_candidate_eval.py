#!/usr/bin/env python3
"""DEV-only candidate observations against an explicitly selected loopback server.

Dry run by default. No credentials, downloads, tool execution or routing writes.
Reports are separate from the production evaluation lab and cannot promote models.
"""

from __future__ import annotations

import argparse
import json
import socket
import time
from datetime import datetime, timezone
from http.client import HTTPException, IncompleteRead
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

if __package__:
    from .benchmark_cases import BENCHMARKS, SYSTEM_INSTRUCTION
else:
    from benchmark_cases import BENCHMARKS, SYSTEM_INSTRUCTION


class EvaluationError(ValueError):
    """An endpoint or response failed the evaluation contract."""


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class LocalClient:
    def __init__(self, base_url: str, model: str, timeout: float = 60):
        parsed = urlsplit(base_url)
        if (
            parsed.scheme != "http"
            or parsed.hostname not in {"127.0.0.1", "::1"}
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
            or parsed.path.rstrip("/") != "/v1"
            or parsed.port is None
            or not 1 <= parsed.port <= 65535
        ):
            raise EvaluationError("Use an explicit HTTP loopback IP, port and /v1 path")
        if not model.strip() or not 0 < timeout <= 300:
            raise EvaluationError("Model is required; timeout must be 1-300 seconds")
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout = timeout
        self.response_evidence: list[dict] = []
        # Ignore ambient proxies and reject redirects to preserve the local boundary.
        self.opener = build_opener(ProxyHandler({}), NoRedirects())

    def request(self, path: str, payload: dict | None = None) -> dict:
        request = Request(
            self.base_url + path,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                raw = response.read(2_000_001)
            self.response_evidence.append({
                "path": path, "raw_response": raw[:2_000_000].decode(errors="replace"),
                "truncated": len(raw) > 2_000_000,
            })
            if len(raw) > 2_000_000:
                raise EvaluationError("Response exceeded 2 MB")
            data = json.loads(raw)
        except HTTPError as exc:
            raise EvaluationError(f"HTTP {exc.code}") from exc
        except HTTPException as exc:
            if isinstance(exc, IncompleteRead) and isinstance(exc.partial, bytes):
                self.response_evidence.append({
                    "path": path,
                    "raw_response": exc.partial[:2_000_000].decode(errors="replace"),
                    "truncated": True,
                })
            raise EvaluationError("Incomplete or invalid HTTP response") from exc
        except (TimeoutError, socket.timeout) as exc:
            raise EvaluationError("Request timed out") from exc
        except (URLError, OSError) as exc:
            raise EvaluationError("Local endpoint unavailable") from exc
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise EvaluationError("Invalid response JSON") from exc
        if not isinstance(data, dict):
            raise EvaluationError("Response must be an object")
        return data

    def verify_model(self) -> None:
        data = self.request("/models").get("data")
        if not isinstance(data, list) or not any(
            isinstance(item, dict) and item.get("id") == self.model for item in data
        ):
            raise EvaluationError("Requested model is absent from the endpoint catalog")

    def chat(self, messages: list[dict], *, tools: list | None = None,
             response_format: dict | None = None) -> dict:
        payload = {
            "model": self.model, "messages": messages, "stream": False,
            "max_tokens": 2048, "temperature": 1.0, "top_p": 0.95, "top_k": 64,
            "chat_template_kwargs": {"reasoning_strength": "low"},
        }
        if tools is not None:
            payload["tools"] = tools
        if response_format is not None:
            payload["response_format"] = response_format
        data = self.request("/chat/completions", payload)
        choices = data.get("choices")
        if not isinstance(choices, list) or len(choices) != 1:
            raise EvaluationError("Expected one completion")
        choice = choices[0]
        if (not isinstance(choice, dict)
                or not isinstance(choice.get("finish_reason"), str)
                or choice["finish_reason"] not in {"stop", "tool_calls"}):
            raise EvaluationError("Incomplete or unsupported completion")
        message = choice.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            raise EvaluationError("Missing assistant message")
        return {"message": message, "usage": data.get("usage"),
                "finish_reason": choice["finish_reason"]}


def final_text(result: dict) -> str:
    message = result["message"]
    content = message.get("content")
    if result["finish_reason"] != "stop" or message.get("tool_calls"):
        raise EvaluationError("Expected a final answer, not a tool call")
    if not isinstance(content, str) or not content.strip():
        raise EvaluationError("Missing final text; reasoning is not an answer")
    if any(marker in content for marker in ("<think>", "</think>", "<|message|>", "<|channel|>")):
        raise EvaluationError("Unparsed reasoning or protocol markers in final text")
    return content.strip()


def messages(prompt: str) -> list[dict]:
    return [{"role": "system", "content": SYSTEM_INSTRUCTION},
            {"role": "user", "content": prompt}]


def extraction_probe(client: LocalClient) -> dict:
    schema = {"type": "object", "properties": {
        "interval_hours": {"type": "integer"}, "source_page": {"type": "integer"}},
        "required": ["interval_hours", "source_page"], "additionalProperties": False}
    result = client.chat(messages(
        'Synthetic manual, page 3: Inspect the belt every 25 hours. '
        'Return only JSON with interval_hours and source_page.'
    ), response_format={"type": "json_object", "schema": schema})
    content = final_text(result)
    parsed = json.loads(content)
    if (not isinstance(parsed, dict) or set(parsed) != {"interval_hours", "source_page"}
            or type(parsed["interval_hours"]) is not int or type(parsed["source_page"]) is not int
            or parsed != {"interval_hours": 25, "source_page": 3}):
        raise EvaluationError("Extraction did not match the synthetic source")
    return {"response": content, "usage": result["usage"]}


def tool_probe(client: LocalClient) -> dict:
    conversation = messages('Call lookup_asset for asset_id demo-pump. After its result, '
                            'reply with only the status value. Do not guess or change anything.')
    tools = [{"type": "function", "function": {
        "name": "lookup_asset", "description": "Read a synthetic asset status.",
        "parameters": {"type": "object", "properties": {"asset_id": {"type": "string"}},
                       "required": ["asset_id"], "additionalProperties": False}}}]
    first = client.chat(conversation, tools=tools)
    calls = first["message"].get("tool_calls")
    if first["finish_reason"] != "tool_calls" or not isinstance(calls, list) or len(calls) != 1:
        raise EvaluationError("Expected exactly one simulated tool call")
    call = calls[0]
    if not isinstance(call, dict):
        raise EvaluationError("Invalid tool call")
    function = call.get("function")
    if (call.get("type") != "function" or not isinstance(call.get("id"), str)
            or not call["id"].strip() or not isinstance(function, dict)
            or function.get("name") != "lookup_asset"
            or not isinstance(function.get("arguments"), str)
            or json.loads(function["arguments"]) != {"asset_id": "demo-pump"}):
        raise EvaluationError("Unexpected tool name or arguments")
    # A fixture is returned; no model-selected code or real tool is executed.
    conversation.extend([first["message"], {"role": "tool", "tool_call_id": call["id"],
                                             "content": '{"status":"inspection_due"}'}])
    final = client.chat(conversation)
    content = final_text(final)
    if content != "inspection_due":
        raise EvaluationError("Tool-result continuation mismatch")
    return {"response": content, "tool_call": call,
            "usage": [first["usage"], final["usage"]]}


def run(client: LocalClient, repeats: int) -> dict:
    report = {"schema_version": 1, "mode": "dev_candidate_observation",
              "started_at": datetime.now(timezone.utc).isoformat(),
              "model": client.model, "base_url": client.base_url,
              "promotion_eligible": False, "human_review_completed": False,
              "artifact_identity_verified": False, "results": []}
    try:
        client.verify_model()
    except EvaluationError as exc:
        report.update(status="blocked", error=str(exc))
        return report
    for repeat in range(1, repeats + 1):
        for case in [{"id": "schema-extraction"}, {"id": "tool-continuation"}, *BENCHMARKS]:
            client.response_evidence = []
            started = time.perf_counter()
            record = {"benchmark_id": case["id"], "repeat": repeat}
            try:
                if case["id"] == "schema-extraction":
                    record.update(extraction_probe(client), status="passed")
                elif case["id"] == "tool-continuation":
                    record.update(tool_probe(client), status="passed")
                else:
                    result = client.chat(messages(case["prompt"]))
                    record.update(response=final_text(result), usage=result["usage"],
                                  status="needs_human_review")
            except (EvaluationError, json.JSONDecodeError) as exc:
                record.update(status="failed", error=str(exc))
            record["latency_seconds"] = round(time.perf_counter() - started, 3)
            record["response_evidence"] = client.response_evidence
            report["results"].append(record)
    report["status"] = "failed" if any(r["status"] == "failed" for r in report["results"]) else "needs_human_review"
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--base-url", default="http://127.0.0.1:18081/v1")
    parser.add_argument("--model", default="muse-glimmer-30b-dev")
    parser.add_argument("--repeats", type=int, choices=range(1, 4), default=3)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    client = LocalClient(args.base_url, args.model)
    if not args.execute:
        print(json.dumps({"mode": "dry_run", "network_requests": 0,
                          "model": args.model, "base_url": args.base_url,
                          "cases": ["schema-extraction", "tool-continuation", *[b["id"] for b in BENCHMARKS]],
                          "repeats": args.repeats, "promotion_eligible": False}, indent=2))
        return 0
    if args.output is None:
        parser.error("--execute requires --output pointing to a new report file")
    # Reserve the output before any request; never overwrite the evaluation lab's reports.
    with args.output.open("x", encoding="utf-8") as handle:
        report = run(client, args.repeats)
        json.dump(report, handle, indent=2)
        handle.write("\n")
    print(f"{report['status']}: {args.output}")
    return 1 if report["status"] in {"blocked", "failed"} else 0


if __name__ == "__main__":
    raise SystemExit(main())
