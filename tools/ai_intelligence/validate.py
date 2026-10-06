#!/usr/bin/env python3
"""Validate the complete AI Intelligence Layer configuration."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config" / "ai_intelligence"

FILES = [
    "model_registry.json",
    "scorecard.json",
    "routing_policy.json",
    "benchmarks.json",
    "technology_watch.json",
    "deployment_map.json",
]

PRODUCTION_STATUSES = {
    "production",
    "production-fallback",
}

KNOWN_STATUSES = PRODUCTION_STATUSES | {
    "evaluation",
    "watch",
    "disabled",
}

ALLOWED_EVIDENCE_CLASS = {
    "canonical",
    "supporting",
    "excluded",
}

CANONICAL_SURFACES = {
    "openclaw",
    "ranchos",
}

ALLOWED_PRODUCT_SURFACES = CANONICAL_SURFACES | {
    "shared_ops",
    "engineering",
}

REJECTED_CANONICAL_SURFACES = {
    "esoteric",
    "generic",
    "public_benchmark",
    "trivia",
}

REQUIRED_REJECTED_EVIDENCE = {
    "esoteric_questions",
    "public_leaderboard_items",
}


def load(name: str) -> dict[str, Any]:
    path = CONFIG / name

    with path.open("r", encoding="utf-8") as handle:
        document = json.load(handle)

    if not isinstance(document, dict):
        raise AssertionError(f"{name} must contain a JSON object")

    return document


def validate_rating_policy(
    scorecard: dict[str, Any],
    benchmarks_document: dict[str, Any],
) -> None:
    policy = scorecard.get("rating_policy")
    assert isinstance(policy, dict), "Scorecard rating_policy is required"
    assert policy.get("primary_evidence") == "ranchos_and_openclaw_prompts", (
        "Scorecard must rate models on RanchOS and OpenClaw prompts"
    )
    rejected = set(policy.get("rejected_evidence", []))
    assert REQUIRED_REJECTED_EVIDENCE <= rejected, (
        "Scorecard must reject esoteric and public-leaderboard evidence: "
        f"{REQUIRED_REJECTED_EVIDENCE - rejected}"
    )

    criteria = scorecard.get("criteria", {})
    for required_criterion in ("ranchos_operations", "openclaw_operations"):
        assert required_criterion in criteria, (
            f"Scorecard is missing {required_criterion}"
        )

    benchmarks = benchmarks_document.get("benchmarks", [])
    benchmark_ids = [benchmark.get("id") for benchmark in benchmarks]
    assert all(benchmark_ids), "Benchmark missing ID"
    assert len(benchmark_ids) == len(set(benchmark_ids)), (
        "Duplicate benchmark IDs"
    )

    gate = benchmarks_document.get("promotion_gate", {})
    assert gate.get("esoteric_or_public_bench_allowed") is False, (
        "Promotion must not accept esoteric or public-bench items"
    )
    required_surfaces = set(gate.get("canonical_surfaces_required", []))
    assert required_surfaces == CANONICAL_SURFACES, (
        "Promotion must require RanchOS and OpenClaw canonical surfaces: "
        f"{required_surfaces}"
    )
    assert gate.get("minimum_canonical_ranchos_benchmarks", 0) >= 2
    assert gate.get("minimum_canonical_openclaw_benchmarks", 0) >= 2

    canonical_surfaces: set[str] = set()
    canonical_count = 0
    for benchmark in benchmarks:
        evidence_class = benchmark.get("evidence_class", "supporting")
        assert evidence_class in ALLOWED_EVIDENCE_CLASS, (
            f"{benchmark.get('id')} has unknown evidence_class "
            f"{evidence_class!r}"
        )
        surface = benchmark.get("product_surface")
        assert surface in ALLOWED_PRODUCT_SURFACES, (
            f"{benchmark.get('id')} has unknown product_surface {surface!r}"
        )
        if evidence_class == "canonical":
            assert surface not in REJECTED_CANONICAL_SURFACES, (
                f"{benchmark.get('id')} cannot be canonical with surface "
                f"{surface!r}"
            )
            assert surface in CANONICAL_SURFACES | {"shared_ops"}, (
                f"{benchmark.get('id')} canonical evidence must be RanchOS, "
                "OpenClaw, or shared operator work"
            )
            canonical_count += 1
            if surface in CANONICAL_SURFACES:
                canonical_surfaces.add(surface)
        if evidence_class == "excluded":
            assert surface in REJECTED_CANONICAL_SURFACES, (
                f"{benchmark.get('id')} excluded evidence must be marked "
                "esoteric, generic, trivia, or public_benchmark"
            )

    assert canonical_count >= 4, (
        "Need at least four canonical RanchOS/OpenClaw operator benchmarks"
    )
    assert CANONICAL_SURFACES <= canonical_surfaces, (
        "Canonical suite must include RanchOS and OpenClaw prompts: "
        f"{CANONICAL_SURFACES - canonical_surfaces}"
    )


def main() -> int:
    documents = {
        name: load(name)
        for name in FILES
    }

    registry = documents["model_registry.json"]
    scorecard = documents["scorecard.json"]
    policy = documents["routing_policy.json"]

    registry_models = registry.get("models", [])
    registry_ids = [
        model["id"]
        for model in registry_models
    ]

    assert len(registry_ids) == len(set(registry_ids)), (
        "Duplicate IDs exist in model registry"
    )

    registry_by_id = {
        model["id"]: model
        for model in registry_models
    }

    score_models = scorecard.get("models", {})
    score_ids = set(score_models)

    assert set(registry_ids) == score_ids, (
        "Registry/scorecard mismatch: "
        f"{set(registry_ids) ^ score_ids}"
    )

    criteria = scorecard.get("criteria", {})

    assert criteria, "Scorecard criteria cannot be empty"

    for criterion, weight in criteria.items():
        assert isinstance(weight, int) and weight > 0, (
            f"Invalid global criterion weight: {criterion}={weight!r}"
        )

    minimum = scorecard.get("scale", {}).get("minimum", 1)
    maximum = scorecard.get("scale", {}).get("maximum", 10)

    for model_id, model in registry_by_id.items():
        status = model.get("status")
        assert status in KNOWN_STATUSES, (
            f"{model_id} has unknown status {status!r}"
        )

        for required_field in [
            "display_name",
            "provider",
            "deployment",
            "privacy_tier",
            "cost_tier",
        ]:
            assert model.get(required_field), (
                f"{model_id} is missing {required_field}"
            )

    for model_id, scores in score_models.items():
        assert set(scores) == set(criteria), (
            f"{model_id} score criteria mismatch: "
            f"{set(scores) ^ set(criteria)}"
        )

        for criterion, value in scores.items():
            assert isinstance(value, (int, float)), (
                f"{model_id}.{criterion} is not numeric"
            )
            assert minimum <= value <= maximum, (
                f"{model_id}.{criterion} outside "
                f"{minimum}-{maximum}"
            )

    rules = policy.get("rules", [])
    task_names = [
        rule.get("task")
        for rule in rules
    ]

    assert len(task_names) == len(set(task_names)), (
        "Duplicate routing task names"
    )

    for rule in rules:
        task = rule.get("task")
        assert task, "Routing rule missing task"

        preferred = rule.get("preferred_models", [])
        fallback = rule.get("fallback_models", [])

        assert preferred, (
            f"{task} must have at least one preferred model"
        )
        assert fallback, (
            f"{task} must have at least one fallback model"
        )

        assert not set(preferred) & set(fallback), (
            f"{task} repeats models across preferred/fallback"
        )

        for model_id in preferred + fallback:
            assert model_id in registry_by_id, (
                f"Unknown routing model: {model_id}"
            )

        allowed_statuses = set(
            rule.get("allowed_statuses", [])
        )

        assert allowed_statuses, (
            f"{task} has no allowed_statuses"
        )
        assert allowed_statuses <= KNOWN_STATUSES, (
            f"{task} contains unknown allowed statuses: "
            f"{allowed_statuses - KNOWN_STATUSES}"
        )

        task_weights = rule.get("criterion_weights", {})

        assert task_weights, (
            f"{task} has no criterion_weights"
        )
        assert set(task_weights) <= set(criteria), (
            f"{task} uses unknown criteria: "
            f"{set(task_weights) - set(criteria)}"
        )

        for criterion, weight in task_weights.items():
            assert isinstance(weight, int) and weight > 0, (
                f"{task}.{criterion} has invalid weight {weight!r}"
            )

        required_privacy = rule.get("required_privacy_tier")

        if required_privacy:
            eligible_local = [
                model_id
                for model_id in preferred + fallback
                if (
                    registry_by_id[model_id].get("privacy_tier")
                    == required_privacy
                    and registry_by_id[model_id].get("status")
                    in allowed_statuses
                )
            ]
            assert eligible_local, (
                f"{task} has no model satisfying privacy/status rules"
            )

        production_candidates = [
            model_id
            for model_id in preferred + fallback
            if registry_by_id[model_id].get("status")
            in PRODUCTION_STATUSES
        ]

        assert production_candidates, (
            f"{task} has no production-capable candidate"
        )

    validate_rating_policy(
        scorecard,
        documents["benchmarks.json"],
    )

    print("AI Intelligence Layer validation: PASS")
    print(f"Models: {len(registry_ids)}")
    print(f"Routing rules: {len(rules)}")
    print(
        "Benchmarks: "
        f"{len(documents['benchmarks.json'].get('benchmarks', []))}"
    )
    print("Rating policy: ranchos_and_openclaw_prompts")
    print("Routing policy schema: "
          f"{policy.get('schema_version')}")
    print("Production-safe status enforcement: PASS")
    print("Task-specific criterion weights: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
