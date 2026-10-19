#!/usr/bin/env python3
"""Publish only Time Machine completion evidence to DEV, using existing SSH."""
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess
import time
from zoneinfo import ZoneInfo


def probe(args):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=12)
        return p.stdout.strip() if p.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def main():
    cache = Path.home() / ".openclaw/status/dev-time-machine-health-evidence.json"
    try:
        previous = json.loads(cache.read_text())
    except (OSError, ValueError):
        previous = {}
    latest = probe(["/usr/bin/tmutil", "latestbackup"])
    status = probe(["/usr/bin/tmutil", "status"])
    stamp = None
    match = re.search(r"/(\d{4}-\d{2}-\d{2}-\d{6})(?:\.backup|/)", latest)
    # Only tmutil's successful destination lookup counts as a completed backup.
    if latest.startswith("/Volumes/") and match:
        stamp = datetime.strptime(match[1], "%Y-%m-%d-%H%M%S").replace(
            tzinfo=ZoneInfo("America/Chicago")).timestamp()
    sample = {"checked_epoch": time.time(),
              "last_destination_backup_epoch": stamp or previous.get("last_destination_backup_epoch"),
              "latest_lookup_ok": stamp is not None,
              "running": bool(re.search(r"Running\s*=\s*1", status))}
    cache.write_text(json.dumps(sample))
    writer = "import json,sys,pathlib; d=json.load(sys.stdin); p=pathlib.Path.home()/'.openclaw-dev/system-health'; p.mkdir(parents=True,exist_ok=True); t=p/'m4.json.tmp'; t.write_text(json.dumps(d)); t.replace(p/'m4.json')"
    import shlex
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                             "SSH-Dev", "python3 -c " + shlex.quote(writer)],
                            input=json.dumps(sample), text=True, capture_output=True, timeout=20)
    if result.returncode:
        raise SystemExit("DEV backup-health publication failed")
    print("M4 backup-health evidence published to DEV")


if __name__ == "__main__":
    main()
