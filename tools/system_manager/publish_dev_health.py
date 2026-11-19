#!/usr/bin/env python3
"""Replicate nonsecret DEV observations with the existing DEV backup connection."""
import json
from pathlib import Path
import shlex
import subprocess
import system_health

report = json.loads((system_health.STATE / "report.json").read_text())
writer = "import json,sys,pathlib; d=json.load(sys.stdin); p=pathlib.Path.home()/'.openclaw/system-health'; p.mkdir(parents=True,exist_ok=True); t=p/'dev-observations.json.tmp'; t.write_text(json.dumps(d)); t.replace(p/'dev-observations.json')"
try:
    p = subprocess.run(system_health.PROD_SSH + ["python3 -c " + shlex.quote(writer)],
                       input=json.dumps(report["observations"]), text=True,
                       capture_output=True, timeout=15)
except (OSError, subprocess.TimeoutExpired):
    raise SystemExit("Production health observation publication unavailable")
if p.returncode:
    raise SystemExit("Production health observation publication failed")
print("DEV health observations published to Production")
