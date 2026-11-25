
import hashlib
import json
import os
import pathlib
import sys

class HardRules:
    """Enforce DEV ONLY, LOCAL MODELS ONLY, READ-ONLY FIRST"""
    @staticmethod
    def enforce_dev():
        if os.getenv("RANCH_ENV", "DEV").upper() != "DEV":
            raise RuntimeError("HARD RULE: Not DEV. Abort.")
        # Block prod paths
        cwd = str(pathlib.Path.cwd()).lower()
        if "prod" in cwd and "dev" not in cwd:
            raise RuntimeError(f"HARD RULE: prod path suspected: {cwd}")

    @staticmethod
    def enforce_local_only():
        # Blocklist external API envs for this pass
        blocked = ["DEEPSEEK_API_KEY", "OPENROUTER_API_KEY"]
        # We don't delete them, but we ensure code does not call them
        # Scanner will grep for external calls
        pass

    @staticmethod
    def enforce_readonly_first(func):
        def wrapper(*args, **kwargs):
            if kwargs.get("state_changing"):
                raise RuntimeError("READ-ONLY FIRST: state-changing probe needs explicit approval")
            return func(*args, **kwargs)
        return wrapper

# Detection & Ejection architecture
ARCHITECTURE_NOTE = """
Design: DETECT AND EJECT vs PLUG GAPS IN ADVANCE

Traditional hardening tries to plug every gap beforehand (allowlist everything, patch everything).
Our model: instrument every input channel as UNTRUSTED, detect anomalous intent, and EJECT.

Components:
1. Channel Tracer: every input channel -> tool access map. Mark untrusted -> trusted boundaries.
2. Prompt Injection Detector (local model Qwen3-Coder/DeepSeek-R1-Distill, 4-bit, MLX/Ollama): 
   scores input for instruction hijack, tool/credential reachability.
3. MCP Firewall: reader (R) separated from doer (D). Crafted message cannot reach destructive tool unless explicitly escalated.
4. FastAPI Auth Gate: unauthenticated probe detector + eject (401 + log + IP ban in DEV).
5. Egress Guard: allowlist + redaction happens BEFORE anything leaves. If redaction fails, EJECT (drop request).
6. Telegram Webhook Guard: secret required, version >=2026.2.1, forged update replay detector.
7. Logger: every probe hashed, tamper-evident chain.

Ejection = drop request + log + alert + quarantine input, NOT silent fix.
"""


def _verify_security_chain(path: pathlib.Path) -> bool:
    previous = "0" * 64
    if not path.exists() or path.stat().st_size == 0:
        return False
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        payload = {key: value for key, value in record.items() if key not in {"ts", "hash", "prev"}}
        digest = hashlib.sha256(
            f"{record.get('prev', '')}{json.dumps(payload, sort_keys=True)}".encode()
        ).hexdigest()
        if record.get("prev") != previous or record.get("hash") != digest:
            return False
        previous = record["hash"]
    return True


def _verify_redteam_chain(path: pathlib.Path) -> bool:
    previous = "0" * 64
    if not path.exists() or path.stat().st_size == 0:
        return False
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        logged = f"[{record.get('ts', '')}] {record.get('level', '')} {record.get('msg', '')}"
        digest = hashlib.sha256(f"{record.get('prev', '')}{logged}".encode()).hexdigest()
        if record.get("prev") != previous or record.get("hash") != digest:
            return False
        previous = record["hash"]
    return True


def verify_chains(root: pathlib.Path | None = None) -> bool:
    root = root or pathlib.Path.cwd()
    security_ok = _verify_security_chain(root / "redteam_logs" / "security_chain.jsonl")
    redteam_ok = _verify_redteam_chain(root / "ranch_redteam_chain.jsonl")
    print(f"security_chain={'PASS' if security_ok else 'FAIL'}")
    print(f"ranch_redteam_chain={'PASS' if redteam_ok else 'FAIL'}")
    return security_ok and redteam_ok


if __name__ == "__main__":
    if "--verify-chain" in sys.argv:
        raise SystemExit(0 if verify_chains() else 1)
    raise SystemExit("usage: ranch_redteam_guards.py --verify-chain")