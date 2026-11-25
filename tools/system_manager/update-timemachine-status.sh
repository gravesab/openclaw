#!/usr/bin/env bash
set -euo pipefail

OUT="$HOME/.openclaw/status/m4_timemachine_status.json"
TMP="$OUT.tmp"

mkdir -p "$(dirname "$OUT")"

python3 - "$TMP" <<'PY'
import json
import plistlib
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlparse

tmp_path = Path(sys.argv[1])


def run(command, timeout=30):
    try:
        result = subprocess.run(
            command,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        return {
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
            "exit_code": result.returncode,
            "timed_out": False,
        }
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""

        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")

        return {
            "stdout": stdout.strip(),
            "stderr": stderr.strip(),
            "exit_code": None,
            "timed_out": True,
        }


def tcp_open(host, port, timeout=3):
    if not host:
        return False

    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


destination = run(["tmutil", "destinationinfo"], timeout=20)
tm_status = run(["tmutil", "status"], timeout=20)
latest = run(["tmutil", "latestbackup"], timeout=30)
mounts = run(["mount"], timeout=15)

destination_text = destination["stdout"]
status_text = tm_status["stdout"]
latest_text = latest["stdout"]

name_match = re.search(
    r"^Name\s*:\s*(.+)$",
    destination_text,
    re.MULTILINE,
)
url_match = re.search(
    r"^URL\s*:\s*(.+)$",
    destination_text,
    re.MULTILINE,
)

destination_name = (
    name_match.group(1).strip()
    if name_match
    else "Unknown"
)

destination_url = (
    url_match.group(1).strip()
    if url_match
    else ""
)

def destination_host(url):
    if not url:
        return ""

    ip_match = re.search(r"@(\d+\.\d+\.\d+\.\d+)/", url)
    if ip_match:
        return ip_match.group(1)

    host = (urlparse(unquote(url)).hostname or "").rstrip(".")
    if host.lower().endswith("._smb._tcp.local"):
        short = host.split("(", 1)[0]
        return f"{short}.local"
    return host


def resolve_ip(host):
    if not host:
        return ""
    if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", host):
        return host

    try:
        infos = socket.getaddrinfo(
            host,
            445,
            socket.AF_INET,
            socket.SOCK_STREAM,
        )
    except OSError:
        return ""

    ips = []
    for info in infos:
        ip = info[4][0]
        if ip not in ips:
            ips.append(ip)

    for ip in ips:
        if tcp_open(ip, 445):
            return ip
    return ips[0] if ips else ""


qnap_ip = resolve_ip(destination_host(destination_url))

running = bool(
    re.search(
        r"\bRunning\s*=\s*1\b",
        status_text,
    )
)

backup_activity = (
    "Currently Running"
    if running
    else "Idle"
)

percent_complete = None

percent_match = re.search(
    r'(?:^|\s)(?:Percent|_raw_Percent)\s*=\s*"?([0-9.]+)"?;',
    status_text,
)

if percent_match:
    try:
        raw_percent = float(percent_match.group(1))

        if 0 <= raw_percent <= 1:
            percent_complete = round(raw_percent * 100)
        elif raw_percent <= 100:
            percent_complete = round(raw_percent)
    except ValueError:
        pass

time_remaining_seconds = None

time_match = re.search(
    r'(?:^|\s)TimeRemaining\s*=\s*"?([0-9.]+)"?;',
    status_text,
)

if time_match:
    try:
        time_remaining_seconds = max(
            0,
            round(float(time_match.group(1))),
        )
    except ValueError:
        pass

backup_phase = ""

phase_match = re.search(
    r'^\s*BackupPhase\s*=\s*"?([^";]+)"?;',
    status_text,
    re.MULTILINE,
)

if phase_match:
    backup_phase = phase_match.group(1).strip()

last_backup = ""

for line in latest_text.splitlines():
    line = line.strip()

    if line.startswith("/"):
        last_backup = line
        break

def plist_snapshot():
    exported = run(
        [
            "defaults",
            "export",
            "/Library/Preferences/com.apple.TimeMachine",
            "-",
        ],
        timeout=15,
    )
    if exported["exit_code"] != 0 or not exported["stdout"]:
        return None

    try:
        data = plistlib.loads(exported["stdout"].encode())
    except (plistlib.InvalidFileException, ValueError, TypeError):
        return None

    destinations = data.get("Destinations") or []
    if not destinations:
        return None

    dest = destinations[0]
    snaps = dest.get("SnapshotDates") or []
    if not snaps:
        return None

    latest_snap = snaps[-1]
    if latest_snap.tzinfo is None:
        latest_snap = latest_snap.replace(tzinfo=timezone.utc)

    interval = int(data.get("AutoBackupInterval") or 86400)
    age = datetime.now(timezone.utc) - latest_snap
    fresh_limit = max(interval * 1.5, 36 * 3600)
    return {
        "result": dest.get("RESULT"),
        "when": latest_snap.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z"),
        "fresh": age.total_seconds() <= fresh_limit,
    }


snapshot = None
if not last_backup and not running:
    snapshot = plist_snapshot()

# backupd: BACKUP_FAILED_DEVICE_LOCKED. The attempt stopped because
# the Mac was locked; Time Machine retries after unlock. It does not
# mean the destination failed.
DEVICE_LOCKED_RESULT = 80

if last_backup:
    health_status = "Current"
    error = ""
elif running:
    health_status = "Currently Running"
    error = ""
elif (
    snapshot
    and snapshot["fresh"]
    and snapshot["result"] in (0, DEVICE_LOCKED_RESULT)
):
    health_status = "Current"
    last_backup = snapshot["when"]
    error = ""
elif snapshot and snapshot["result"] == DEVICE_LOCKED_RESULT:
    health_status = "Stale"
    last_backup = snapshot["when"]
    error = (
        "Last attempt skipped because the Mac was locked; "
        f"last snapshot {snapshot['when']}"
    )
elif snapshot and snapshot["result"] not in (None, 0):
    health_status = "Failed"
    error = (
        f"Time Machine result {snapshot['result']}; "
        f"last snapshot {snapshot['when']}"
    )
elif snapshot and not snapshot["fresh"]:
    health_status = "Stale"
    error = f"Last snapshot {snapshot['when']}"
elif latest["timed_out"]:
    health_status = "Unknown"
    error = "tmutil latestbackup timed out"
else:
    health_status = "Unknown"
    error = (
        latest["stderr"]
        or latest_text
        or "tmutil latestbackup returned no result"
    )

mount_lines = [
    line
    for line in mounts["stdout"].splitlines()
    if any(
        term in line.lower()
        for term in (
            "mactimemachine",
            ".timemachine",
            "time machine",
            "smbfs",
        )
    )
]

if qnap_ip:
    ping_result = run(
        ["ping", "-c", "1", "-W", "1000", qnap_ip],
        timeout=5,
    )
else:
    ping_result = {"exit_code": 1}

data = {
    "checked_at": datetime.now().astimezone().strftime(
        "%Y-%m-%d %H:%M:%S %Z"
    ),
    "host": subprocess.run(
        ["hostname"],
        text=True,
        capture_output=True,
    ).stdout.strip(),
    "destination_name": destination_name,
    "destination_configured": str(
        bool(destination_url)
    ).lower(),
    "destination_url": destination_url,
    "qnap_ip": qnap_ip,
    "qnap_ping": (
        "up"
        if ping_result.get("exit_code") == 0
        else "down"
    ),
    "smb_445": (
        "open"
        if tcp_open(qnap_ip, 445)
        else "closed"
    ),
    "time_machine_running": str(running).lower(),
    "backup_activity": backup_activity,
    "backup_phase": backup_phase,
    "percent_complete": percent_complete,
    "time_remaining_seconds": time_remaining_seconds,
    "status": health_status,
    "last_backup_path": last_backup,
    "error": error,
    "mounts": "\n".join(mount_lines),
    "collector": {
        "destinationinfo_timed_out": destination["timed_out"],
        "status_timed_out": tm_status["timed_out"],
        "latestbackup_timed_out": latest["timed_out"],
    },
}

tmp_path.write_text(
    json.dumps(data, indent=2) + "\n"
)
PY

mv "$TMP" "$OUT"
