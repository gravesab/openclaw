#!/usr/bin/env python3
"""Checkpointed, local-only PDF extraction for PropertyManager handbook review."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from time import perf_counter
from typing import Any

from run_local_llm_handbook_eval import (
    call_routed_model,
    excerpt_is_supported,
    extract_pages,
    is_private_ollama_url,
    parse_model_json,
    resolve_dev_local_route,
    select_routed_model,
    sha256_file,
)


def write_checkpoint(path: Path, value: dict[str, Any]) -> None:
    """Atomically persist progress after every completed source page."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def load_checkpoint(path: Path, fixture: Path) -> dict[str, Any]:
    if path.exists():
        checkpoint = json.loads(path.read_text(encoding="utf-8"))
        if checkpoint.get("source", {}).get("sha256") != sha256_file(fixture):
            raise ValueError("Checkpoint belongs to a different PDF")
        return checkpoint
    return {"schema_version": 1, "source": {"file_name": fixture.name, "sha256": sha256_file(fixture)}, "pages": {}, "complete": False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--ollama-url", default="http://192.168.50.117:11434")
    parser.add_argument("--timeout-seconds", type=float, default=180)
    args = parser.parse_args()
    checkpoint = load_checkpoint(args.checkpoint, args.fixture)
    base_url = is_private_ollama_url(args.ollama_url)
    route = resolve_dev_local_route("property_manager_handbook_evaluation")
    model, unavailable = select_routed_model(route, ollama_url=base_url, timeout_seconds=15)
    checkpoint["routing"] = {**route, "selected_model_id": model["model_id"], "unavailable_candidates": unavailable}
    for page in extract_pages(args.fixture):
        key = str(page["page"])
        if checkpoint["pages"].get(key, {}).get("status") == "complete":
            continue
        prompt = f'''Return JSON only: {{"records":[{{"kind":"procedure|tool|part|warning|specification","title":"string","value":"string","citations":[{{"page":{page['page']},"excerpt":"verbatim <=16 words"}}]}}]}}. Use only this page. Every excerpt must be contiguous and verbatim.\n\nPAGE {page['page']}:\n{page['text']}'''
        started = perf_counter()
        try:
            raw, _, _ = call_routed_model(candidate=model, ollama_url=base_url, prompt=prompt, timeout_seconds=args.timeout_seconds)
            parsed, repair = parse_model_json(raw)
            records = (parsed or {}).get("records", []) if isinstance(parsed, dict) else []
            accepted = [record for record in records if isinstance(record, dict) and any(isinstance(citation, dict) and citation.get("page") == page["page"] and isinstance(citation.get("excerpt"), str) and excerpt_is_supported(citation["excerpt"], page["text"]) for citation in record.get("citations", []))]
            checkpoint["pages"][key] = {"status": "complete", "duration_ms": round((perf_counter() - started) * 1000), "format_repair": repair, "records": accepted}
        except Exception as exc:  # Retain failure for a targeted retry on next run.
            checkpoint["pages"][key] = {"status": "failed", "error": type(exc).__name__}
        write_checkpoint(args.checkpoint, checkpoint)
    checkpoint["complete"] = all(value.get("status") == "complete" for value in checkpoint["pages"].values())
    write_checkpoint(args.checkpoint, checkpoint)
    print(json.dumps({"checkpoint": str(args.checkpoint), "complete": checkpoint["complete"], "pages": len(checkpoint["pages"])}))
    return 0 if checkpoint["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
