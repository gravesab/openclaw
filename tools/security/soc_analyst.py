"""Local SOC proposal writer. Stores a diff suggestion and does not apply it."""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

_LOOPBACK = {"127.0.0.1", "localhost", "::1"}
_PROMPT = (
    "You are Ranch SOC, local-only. Given incident JSON, return JSON with "
    "is_breach, confidence, patch_file, patch_diff, and reason. "
    "Do not claim the patch was applied."
)


def _local_generate_url() -> str:
    url = os.environ.get("OPENCLAW_OLLAMA_GENERATE_URL", "http://127.0.0.1:11434/api/generate")
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in _LOOPBACK:
        raise ValueError("SOC analyst accepts only a loopback Ollama URL")
    return url


def propose_patch(incident: dict) -> Path:
    """Ask the local model for a patch and write it for a person to review."""

    destination_dir = Path(__file__).resolve().parents[2] / "redteam_logs" / "soc_proposals"
    destination_dir.mkdir(parents=True, exist_ok=True)
    incident_id = str(incident.get("hash", "incident"))[:12]
    destination = destination_dir / f"{incident_id}.json"
    proposal = {
        "incident_id": incident_id,
        "status": "awaiting_human_approval",
        "applied": False,
    }
    try:
        body = json.dumps({
            "model": os.environ.get("RANCH_DETECTOR_MODEL", "qwen3.5:9b"),
            "prompt": f"{_PROMPT}\n\nIncident:\n{json.dumps(incident, sort_keys=True)[:4000]}",
            "stream": False,
            "format": "json",
            "options": {"temperature": 0.0},
        }).encode("utf-8")
        request = Request(
            _local_generate_url(),
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
        proposal["model_response"] = str(payload.get("response", ""))[:4000]
    except Exception as exc:
        proposal["model_error"] = type(exc).__name__
    destination.write_text(json.dumps(proposal, indent=2, sort_keys=True))
    return destination
