"""Deterministic handbook fact scoring. No network, routing, or extraction."""

from __future__ import annotations

import json
import re
from typing import Any


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
        return {
            "passed": False,
            "accuracy": 0.0,
            "hallucination_count": 1,
            "findings": [{"type": "schema", "detail": "facts must be an array"}],
        }
    correct = 0
    hallucinations = 0
    for raw in facts:
        if not isinstance(raw, dict):
            hallucinations += 1
            findings.append({"type": "schema", "detail": "fact must be an object"})
            continue
        fact_id = raw.get("id")
        if fact_id not in expected or fact_id in seen:
            hallucinations += 1
            findings.append({"type": "unsupported_fact", "id": fact_id})
            continue
        seen.add(fact_id)
        citations = raw.get("citations")
        cited_pages = (
            {
                citation.get("page")
                for citation in citations
                if isinstance(citation, dict) and isinstance(citation.get("page"), int)
            }
            if isinstance(citations, list)
            else set()
        )
        if not cited_pages or not (cited_pages & set(expected[fact_id]["pages"])):
            hallucinations += 1
            findings.append(
                {
                    "type": "unsupported_citation",
                    "id": fact_id,
                    "expected_pages": expected[fact_id]["pages"],
                    "actual_pages": sorted(cited_pages),
                }
            )
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
            findings.append(
                {
                    "type": "incorrect_value",
                    "id": fact_id,
                    "expected": expected[fact_id]["value"],
                    "actual": raw.get("value"),
                }
            )
    for fact_id in sorted(set(expected) - seen):
        findings.append({"type": "missing_fact", "id": fact_id})
    total = len(expected)
    return {
        "passed": correct == total and hallucinations == 0,
        "accuracy": round(correct / total, 4),
        "correct_fact_count": correct,
        "expected_fact_count": total,
        "hallucination_count": hallucinations,
        "findings": findings,
    }
