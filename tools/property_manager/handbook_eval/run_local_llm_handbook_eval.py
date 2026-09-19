#!/usr/bin/env python3
"""Evaluate router-selected local LLM handbook extraction in DEV only.

This tool reads a PDF and the versioned DEV AI-routing configuration. It never
imports or calls PropertyManager API/database code, refuses external models and
public endpoints, and writes only an ignored local report.
"""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import re
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path
from time import perf_counter
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_ANSWER_KEY = Path(__file__).with_name("fixtures") / "dr_chipper_answer_key.json"
DEFAULT_OLLAMA_URL = "http://192.168.50.117:11434"

if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


class EvaluationError(ValueError):
    """Raised for a controlled evaluation failure."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_private_local_url(raw_url: str) -> str:
    """Normalize a local provider URL and reject public/credential-bearing targets."""
    parsed = urlparse(raw_url.rstrip("/"))
    if parsed.scheme != "http" or not parsed.hostname or parsed.username or parsed.password:
        raise EvaluationError("Provider URL must be credential-free http://private-host[:port]")
    try:
        addresses = {ipaddress.ip_address(info[4][0]) for info in socket.getaddrinfo(parsed.hostname, parsed.port or 80)}
    except OSError as exc:
        raise EvaluationError(f"Cannot resolve local provider host: {parsed.hostname}") from exc
    if not addresses or not all(address.is_private or address.is_loopback for address in addresses):
        raise EvaluationError("DEV-only evaluation rejects non-private model endpoints")
    return raw_url.rstrip("/")


def is_private_ollama_url(raw_url: str) -> str:
    """Compatibility wrapper for callers that configure the Ollama endpoint."""
    return is_private_local_url(raw_url)


def resolve_dev_local_route(component_id: str) -> dict[str, Any]:
    """Resolve the local-only candidate chain from the router's source config.

    The DB-backed runtime router receives these assignments during deployment.
    The evaluator deliberately reads the validated source plan because it has
    no database credentials and must not write routing telemetry.
    """
    try:
        from tools.ai_intelligence.load_configuration import build_plan
    except ImportError as exc:
        raise EvaluationError("Cannot load the DEV AI routing configuration") from exc

    plan = build_plan()
    components = {
        item["component_id"]: item
        for item in plan.components
    }
    component = components.get(component_id)
    if component is None:
        raise EvaluationError(f"Unknown routed component: {component_id}")
    if component["privacy_tier"] != "local":
        raise EvaluationError(
            f"DEV handbook evaluation requires a local component, got "
            f"{component['privacy_tier']!r}"
        )

    models = {item["model_id"]: item for item in plan.models}
    assignments = sorted(
        (
            item
            for item in plan.assignments
            if item["component_id"] == component_id
        ),
        key=lambda item: (
            0 if item["assignment_type"] == "primary" else 1,
            item["priority"],
            item["model_id"],
        ),
    )
    if not assignments:
        raise EvaluationError(f"No configured route for component: {component_id}")

    candidates: list[dict[str, Any]] = []
    for assignment in assignments:
        model = models.get(assignment["model_id"])
        if model is None:
            raise EvaluationError(
                f"Route references unknown model: {assignment['model_id']}"
            )
        if model["deployment"] != "local" or model["privacy_tier"] != "local":
            raise EvaluationError(
                f"DEV handbook route contains a non-local model: {model['id']}"
            )
        candidates.append(
            {
                "model_id": model["model_id"],
                "display_name": model["display_name"],
                "provider": model["provider"],
                "deployment": model["deployment"],
                "assignment_type": assignment["assignment_type"],
                "priority": assignment["priority"],
            }
        )
    return {
        "source": "config/ai_intelligence/deployment_map.json",
        "component_id": component_id,
        "component_name": component["display_name"],
        "task_type": component["task_type"],
        "privacy_tier": component["privacy_tier"],
        "candidates": candidates,
    }


def available_ollama_models(base_url: str, timeout_seconds: float) -> set[str]:
    request = Request(f"{base_url}/api/tags", headers={"Accept": "application/json"})
    try:
        with urlopen(request, timeout=timeout_seconds) as response:
            payload = json.loads(response.read().decode())
    except (HTTPError, URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        raise EvaluationError(
            f"Cannot inspect the private Ollama model inventory: {type(exc).__name__}: {exc}"
        ) from exc
    models = payload.get("models") if isinstance(payload, dict) else None
    if not isinstance(models, list):
        raise EvaluationError("Private Ollama model inventory has an invalid shape")
    return {
        item["name"]
        for item in models
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }


def select_routed_model(
    route: dict[str, Any], *, ollama_url: str, timeout_seconds: float
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    """Choose the first available local candidate without changing the route."""
    from tools.ai_intelligence.ollama_config import to_ollama_model_name
    from tools.ai_intelligence.omlx_config import is_omlx_configured

    ollama_models = available_ollama_models(ollama_url, timeout_seconds)
    unavailable: list[dict[str, str]] = []
    for candidate in route["candidates"]:
        model_id = candidate["model_id"]
        if model_id.startswith("omlx-"):
            if is_omlx_configured():
                return candidate, unavailable
            unavailable.append({"model_id": model_id, "reason": "omlx-not-configured"})
            continue
        if model_id.startswith("ollama-"):
            try:
                ollama_name = to_ollama_model_name(model_id)
            except ValueError as exc:
                unavailable.append({"model_id": model_id, "reason": str(exc)})
                continue
            if ollama_name in ollama_models:
                return candidate, unavailable
            unavailable.append(
                {"model_id": model_id, "reason": f"not-installed:{ollama_name}"}
            )
            continue
        unavailable.append({"model_id": model_id, "reason": "unsupported-local-provider"})
    raise EvaluationError("No router-selected local model is available")


def extract_pages(pdf_path: Path) -> list[dict[str, Any]]:
    """Extract text per page while keeping citations tied to source page numbers."""
    try:
        from pypdf import PdfReader
    except ImportError:
        try:
            import pdfplumber
        except ImportError as exc:
            raise EvaluationError("Install pypdf or pdfplumber to extract handbook text") from exc
        with pdfplumber.open(pdf_path) as pdf:
            return [
                {"page": index, "text": (page.extract_text() or "").strip()}
                for index, page in enumerate(pdf.pages, start=1)
            ]
    reader = PdfReader(str(pdf_path))
    return [
        {"page": index, "text": (page.extract_text() or "").strip()}
        for index, page in enumerate(reader.pages, start=1)
    ]


def build_prompt(
    page: dict[str, Any], facts: list[dict[str, Any]], *, context_window_tokens: int
) -> str:
    """Ask one bounded, cited question so small local contexts remain usable."""
    # Reserve enough output room for JSON/citations and use a conservative three
    # characters per token. A page over this size needs a retrieval chunker,
    # never silent truncation that could hide supporting evidence.
    max_source_characters = max(0, (context_window_tokens - 900) * 3)
    if len(page["text"]) > max_source_characters:
        raise EvaluationError(
            f"Page {page['page']} is {len(page['text'])} characters, exceeding the "
            f"safe {max_source_characters}-character source budget for a "
            f"{context_window_tokens}-token context"
        )
    fact_requirements = "; ".join(
        (
            f"{fact['id']} (citation must include: "
            f"{', '.join(fact['citation_terms'])})"
            if fact.get("citation_terms")
            else fact["id"]
        )
        for fact in facts
    )
    return f"""You extract a maintenance handbook into a strict evidence record.
Return JSON only, with exactly this shape:
{{"facts":[{{"id":"one required id","value":"string or null","citations":[{{"page":{page['page']},"excerpt":"short supporting excerpt"}}]}}]}}

Required fact IDs: {fact_requirements}.
Return each required fact exactly once. Each id field MUST be one of those literal strings; never put an answer value in id. Do not invent a model number; use null when it is not stated.
For a safety prerequisite, preserve every ordered precondition stated by the source; do not omit a control action such as disengaging a PTO.
Use only the source page below. Every answer needs one citation with this exact page number and a contiguous excerpt copied verbatim from the page (at most 16 words). The excerpt must directly support the fact's answer, especially a safety action, measurement, interval, or part number. Do not combine excerpts, paraphrase an excerpt, or use an ellipsis. Do not add keys or facts.

HANDBOOK PAGE {page['page']}:
{page['text']}
"""


def call_ollama(*, base_url: str, model: str, prompt: str, timeout_seconds: float) -> tuple[str, int]:
    body = json.dumps({"model": model, "prompt": prompt, "stream": False, "format": "json", "think": False, "options": {"temperature": 0}}).encode()
    request = Request(f"{base_url}/api/generate", data=body, headers={"Content-Type": "application/json"}, method="POST")
    started = perf_counter()
    try:
        with urlopen(request, timeout=timeout_seconds) as response:
            payload = json.loads(response.read().decode())
    except (HTTPError, URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        raise EvaluationError(f"Local Ollama request failed: {type(exc).__name__}: {exc}") from exc
    content = payload.get("response") if isinstance(payload, dict) else None
    if not isinstance(content, str) or not content.strip():
        raise EvaluationError("Local Ollama response did not contain non-empty text")
    return content, round((perf_counter() - started) * 1000)


def call_routed_model(
    *,
    candidate: dict[str, Any],
    ollama_url: str,
    prompt: str,
    timeout_seconds: float,
) -> tuple[str, int, str]:
    """Run a routed local candidate without invoking routing telemetry."""
    model_id = candidate["model_id"]
    if model_id.startswith("ollama-"):
        from tools.ai_intelligence.ollama_config import to_ollama_model_name

        content, duration_ms = call_ollama(
            base_url=ollama_url,
            model=to_ollama_model_name(model_id),
            prompt=prompt,
            timeout_seconds=timeout_seconds,
        )
        return content, duration_ms, to_ollama_model_name(model_id)

    if model_id.startswith("omlx-"):
        from tools.ai_intelligence.execution_models import ProviderRequest
        from tools.ai_intelligence.omlx_config import OMLXConfig
        from tools.ai_intelligence.omlx_provider import OMLXProvider
        from tools.ai_intelligence.provider import ProviderError

        try:
            config = OMLXConfig.from_env()
            is_private_local_url(config.base_url)
            response = OMLXProvider(config).execute(
                ProviderRequest(
                    model_id=model_id,
                    prompt=prompt,
                    request_id=str(uuid4()),
                    timeout_seconds=timeout_seconds,
                    parameters={"temperature": 0},
                )
            )
        except ProviderError as exc:
            raise EvaluationError(f"Local oMLX request failed: {exc}") from exc
        return response.content, response.duration_ms, model_id

    raise EvaluationError(f"Unsupported router-selected model: {model_id}")


def parse_model_json(raw_response: str) -> tuple[dict[str, Any] | None, str | None]:
    """Parse JSON, tolerating a single Markdown fence as an adapter repair."""
    try:
        parsed = json.loads(raw_response)
    except json.JSONDecodeError:
        stripped = raw_response.strip()
        if not (stripped.startswith("```json") and stripped.endswith("```")):
            return None, None
        try:
            parsed = json.loads(stripped[len("```json") : -3].strip())
        except json.JSONDecodeError:
            return None, None
        repair = "markdown_json_fence"
    else:
        repair = None
    return (parsed if isinstance(parsed, dict) else None), repair


def normalize(value: Any) -> str:
    if value is None:
        return "<null>"
    return " ".join(str(value).casefold().replace("-", " ").split())


def normalize_source_text(value: str) -> str:
    """Normalize text for a whitespace/punctuation-tolerant source excerpt check."""
    return " ".join(re.sub(r"[^a-z0-9]+", " ", value.casefold()).split())


def excerpt_is_supported(excerpt: str, source_text: str) -> bool:
    """Accept a literal excerpt or a truthful ellipsis-separated elision."""
    normalized_source = normalize_source_text(source_text)
    normalized_excerpt = normalize_source_text(excerpt)
    if normalized_excerpt and normalized_excerpt in normalized_source:
        return True
    if "..." not in excerpt and "…" not in excerpt:
        return False
    segments = [
        normalize_source_text(segment)
        for segment in re.split(r"(?:\.\.\.|…)", excerpt)
    ]
    position = 0
    for segment in segments:
        if not segment:
            continue
        position = normalized_source.find(segment, position)
        if position < 0:
            return False
        position += len(segment)
    return True


def value_matches(actual: Any, expected_fact: dict[str, Any]) -> bool:
    values = [expected_fact["value"], *expected_fact.get("acceptable_values", [])]
    if normalize(actual) in {normalize(value) for value in values}:
        return True
    required_terms = expected_fact.get("required_terms")
    if not isinstance(required_terms, list) or not isinstance(actual, str):
        return False
    normalized_actual = normalize(actual)
    return all(
        isinstance(term, str) and normalize(term) in normalized_actual
        for term in required_terms
    )


def score_response(
    candidate: Any,
    answer_key: dict[str, Any],
    *,
    source_pages: dict[int, str] | None = None,
) -> dict[str, Any]:
    """Score exact fixture facts and flag unsupported/invalid output as hallucinations."""
    expected = {fact["id"]: fact for fact in answer_key["expected_facts"]}
    findings: list[dict[str, Any]] = []
    seen: set[str] = set()
    facts = candidate.get("facts") if isinstance(candidate, dict) else None
    if not isinstance(facts, list):
        return {"passed": False, "accuracy": 0.0, "hallucination_count": 1, "findings": [{"type": "schema", "detail": "facts must be an array"}]}
    correct = 0
    hallucinations = 0
    for raw in facts:
        if not isinstance(raw, dict):
            hallucinations += 1; findings.append({"type": "schema", "detail": "fact must be an object"}); continue
        fact_id = raw.get("id")
        if fact_id not in expected or fact_id in seen:
            hallucinations += 1; findings.append({"type": "unsupported_fact", "id": fact_id}); continue
        seen.add(fact_id)
        citations = raw.get("citations")
        cited_pages = {citation.get("page") for citation in citations if isinstance(citation, dict) and isinstance(citation.get("page"), int)} if isinstance(citations, list) else set()
        if not cited_pages or not (cited_pages & set(expected[fact_id]["pages"])):
            hallucinations += 1; findings.append({"type": "unsupported_citation", "id": fact_id, "expected_pages": expected[fact_id]["pages"], "actual_pages": sorted(cited_pages)})
            continue
        if source_pages is not None:
            source_supported = any(
                isinstance(citation, dict)
                and citation.get("page") in expected[fact_id]["pages"]
                and isinstance(citation.get("excerpt"), str)
                and excerpt_is_supported(
                    citation["excerpt"],
                    source_pages.get(citation["page"], ""),
                )
                for citation in citations
            )
            if not source_supported:
                hallucinations += 1
                findings.append({"type": "unsupported_excerpt", "id": fact_id})
                continue
            citation_terms = expected[fact_id].get("citation_terms")
            if isinstance(citation_terms, list) and citation_terms:
                citation_supports_fact = any(
                    isinstance(citation, dict)
                    and citation.get("page") in expected[fact_id]["pages"]
                    and isinstance(citation.get("excerpt"), str)
                    and all(
                        isinstance(term, str)
                        and normalize_source_text(term)
                        in normalize_source_text(citation["excerpt"])
                        for term in citation_terms
                    )
                    for citation in citations
                )
                if not citation_supports_fact:
                    hallucinations += 1
                    findings.append({"type": "unsupported_fact_excerpt", "id": fact_id})
                    continue
        if value_matches(raw.get("value"), expected[fact_id]):
            correct += 1
        else:
            findings.append({"type": "incorrect_value", "id": fact_id, "expected": expected[fact_id]["value"], "actual": raw.get("value")})
    for fact_id in sorted(set(expected) - seen):
        findings.append({"type": "missing_fact", "id": fact_id})
    total = len(expected)
    return {"passed": correct == total and hallucinations == 0, "accuracy": round(correct / total, 4), "correct_fact_count": correct, "expected_fact_count": total, "hallucination_count": hallucinations, "findings": findings}


def run_evaluation(
    *, fixture: Path, answer_key_path: Path, component_id: str, ollama_url: str,
    timeout_seconds: float, context_window_tokens: int,
) -> dict[str, Any]:
    if not fixture.is_file():
        raise EvaluationError(f"Fixture not found: {fixture}")
    answer_key = json.loads(answer_key_path.read_text(encoding="utf-8"))
    pages = extract_pages(fixture)
    pages_by_number = {page["page"]: page for page in pages}
    private_url = is_private_ollama_url(ollama_url)
    route = resolve_dev_local_route(component_id)
    selected_candidate, unavailable_candidates = select_routed_model(
        route, ollama_url=private_url, timeout_seconds=timeout_seconds
    )
    candidate_facts: list[Any] = []
    raw_responses: list[dict[str, Any]] = []
    format_findings: list[dict[str, Any]] = []
    format_repairs: list[dict[str, Any]] = []
    duration_ms = 0
    facts_by_page: dict[int, list[dict[str, Any]]] = {}
    for fact in answer_key["expected_facts"]:
        facts_by_page.setdefault(fact["pages"][0], []).append(fact)
    for page_number, expected_facts in facts_by_page.items():
        source_page = pages_by_number.get(page_number)
        if source_page is None or not source_page["text"]:
            raise EvaluationError(f"Fixture has no extractable text for page {page_number}")
        raw_response, call_duration_ms, provider_model_name = call_routed_model(
            candidate=selected_candidate,
            ollama_url=private_url,
            prompt=build_prompt(
                source_page, expected_facts, context_window_tokens=context_window_tokens
            ),
            timeout_seconds=timeout_seconds,
        )
        duration_ms += call_duration_ms
        raw_responses.append({"page": page_number, "fact_ids": [fact["id"] for fact in expected_facts], "provider_model_name": provider_model_name, "response": raw_response})
        parsed, repair = parse_model_json(raw_response)
        if repair is not None:
            format_repairs.append({"type": repair, "page": page_number})
        if parsed is None:
            candidate_facts.extend({"id": fact["id"], "invalid_json": True} for fact in expected_facts)
            format_findings.append({"type": "invalid_json", "page": page_number})
        else:
            facts = parsed.get("facts")
            if not isinstance(facts, list):
                candidate_facts.extend({"id": fact["id"], "invalid_json": True} for fact in expected_facts)
                format_findings.append({"type": "invalid_shape", "page": page_number})
            else:
                candidate_facts.extend(facts)
    candidate = {"facts": candidate_facts}
    score = score_response(
        candidate,
        answer_key,
        source_pages={page["page"]: page["text"] for page in pages},
    )
    score["format_error_count"] = len(format_findings)
    score["format_findings"] = format_findings
    score["format_repair_count"] = len(format_repairs)
    score["format_repairs"] = format_repairs
    score["passed"] = bool(score["passed"] and not format_findings)
    return {"schema_version": 1, "evaluation_id": str(uuid4()), "environment": "development-local-only", "source": {"file_name": fixture.name, "sha256": sha256_file(fixture), "page_count": len(pages)}, "reviewed_answer_key": {"file_name": answer_key_path.name, "sha256": sha256_file(answer_key_path), "fixture_id": answer_key.get("fixture_id")}, "routing": {**route, "unavailable_candidates": unavailable_candidates, "selected_model_id": selected_candidate["model_id"]}, "model": {"provider": selected_candidate["provider"], "model_id": selected_candidate["model_id"], "base_url": private_url if selected_candidate["model_id"].startswith("ollama-") else "configured-local-omlx", "context_window_tokens": context_window_tokens}, "duration_ms": duration_ms, "candidate": candidate, "raw_model_responses": raw_responses, "score": score}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--answer-key", type=Path, default=DEFAULT_ANSWER_KEY)
    parser.add_argument(
        "--component-id",
        default="property_manager_handbook_evaluation",
    )
    parser.add_argument("--ollama-url", default=DEFAULT_OLLAMA_URL)
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--context-window-tokens", type=int, default=4096)
    parser.add_argument("--output", type=Path, default=ROOT / "reports" / "property_manager" / "handbook_eval" / "dr_chipper_latest.json")
    args = parser.parse_args()
    try:
        report = run_evaluation(fixture=args.fixture, answer_key_path=args.answer_key, component_id=args.component_id, ollama_url=args.ollama_url, timeout_seconds=args.timeout_seconds, context_window_tokens=args.context_window_tokens)
    except EvaluationError as exc:
        print(f"evaluation failed: {exc}", file=sys.stderr)
        return 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "passed": report["score"]["passed"], "accuracy": report["score"]["accuracy"], "hallucination_count": report["score"]["hallucination_count"]}, indent=2))
    return 0 if report["score"]["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
