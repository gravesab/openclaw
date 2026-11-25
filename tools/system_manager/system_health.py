#!/usr/bin/env python3
"""Bounded, deterministic infrastructure health reporting for DEV Telegram."""
import argparse
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
import urllib.parse
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

ZONE = ZoneInfo("America/Chicago")
ENVIRONMENT = os.environ.get("OPENCLAW_HEALTH_ENV", "dev")
CONFIG_DIR = Path.home() / (".openclaw" if ENVIRONMENT == "prod" else ".openclaw-dev")
STATE = CONFIG_DIR / "system-health"
PROD_SSH = ["ssh", "-i", str(Path.home() / ".ssh/openclaw_dev_backup_ed25519"),
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=yes", "gravesab@100.85.36.72"]


def run(args, timeout=12, include_stderr=False):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.stdout + (p.stderr if include_stderr else "") if p.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def journal(unit, remote=False, user=True, days=10):
    args = ["journalctl", *(["--user"] if user else []), "-u", unit,
            "--since", f"{days} days ago", "-n", "2000", "-o", "json", "--no-pager"]
    output = run(PROD_SSH + [shlex.join(args)] if remote else args)
    if output is None:
        return None
    rows = []
    for line in output.splitlines():
        try:
            row = json.loads(line)
            rows.append((int(row["__REALTIME_TIMESTAMP"]) / 1e6, row.get("MESSAGE", "")))
        except (ValueError, KeyError, TypeError):
            continue
    return rows


def last_matching(rows, phrase):
    return max((stamp for stamp, message in rows or [] if phrase in message), default=None)


def backup_label(stamp, now, max_age):
    if stamp is None or stamp > now + 300:
        return "Unknown"
    when = datetime.fromtimestamp(stamp, ZONE).strftime("%b %d %H:%M")
    return f"{'Current' if now - stamp <= max_age else 'Overdue'} ({when})"


def collect(now=None):
    now = now or time.time()
    feed = {}
    if ENVIRONMENT == "prod":
        try:
            feed = json.loads((STATE / "dev-observations.json").read_text())
            if not 0 <= now - feed["checked_epoch"] <= 900:
                feed = {}
        except (OSError, ValueError, KeyError, TypeError):
            pass
    remote_prod = ENVIRONMENT != "prod"
    def prod_run(args):
        return run(PROD_SSH + [shlex.join(args)] if remote_prod else args)
    jobs = {
        "prod_gateway": lambda: journal("openclaw-gateway.service", remote=remote_prod, days=1),
        "prod_channel": lambda: run(PROD_SSH + [shlex.join(["node", "/home/gravesab/ai/projects/openclaw/dist/index.js", "channels", "status", "--json"])] if remote_prod else ["node", "/home/gravesab/ai/projects/openclaw/dist/index.js", "channels", "status", "--json"], timeout=25),
        "prod_backup": lambda: journal("openclaw-backup-watchdog.service", remote=remote_prod),
        "prod_audio": lambda: journal("openclaw-listener.service", remote=remote_prod, user=False, days=1),
        "dev_backup": lambda: journal("openclaw-dev-backup.service"),
        "prod_failed": lambda: prod_run(["systemctl", "--failed", "--plain", "--no-legend", "--no-pager"]),
        "prod_disk": lambda: prod_run(["df", "-P", "/", "/mnt/ai-storage", "/mnt/qnap-backup"]),
        "prod_mem": lambda: prod_run(["free", "-m"]),
        "dev_failed": lambda: run(["systemctl", "--user", "--failed", "--plain", "--no-legend", "--no-pager"]),
        "dev_disk": lambda: run(["df", "-P", "/"]),
        "dev_gateway": lambda: run(["docker", "inspect", "openclawdev-openclaw-gateway-1", "--format", "{{.State.Status}} {{.State.Health.Status}}"]),
        "dev_logs": lambda: run(["docker", "logs", "--since", "30m", "--tail", "200", "openclawdev-openclaw-gateway-1"], include_stderr=True),
    }
    if ENVIRONMENT == "prod":
        for key in list(jobs):
            if key.startswith("dev_"):
                jobs[key] = lambda key=key: feed.get("values", {}).get(key)
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        futures = {key: pool.submit(fn) for key, fn in jobs.items()}
        values = {key: future.result() for key, future in futures.items()}
    issues = []
    audio_failure = last_matching(values["prod_audio"], "audio open error: No such device")
    if audio_failure and now - audio_failure < 300:
        issues.append("Production microphone unavailable")
    memory = values["prod_mem"]
    if memory is None:
        issues.append("Production memory health unavailable")
    else:
        for line in memory.splitlines():
            fields = line.split()
            if fields and fields[0] == "Mem:" and len(fields) >= 7:
                if int(fields[-1]) / max(1, int(fields[1])) < 0.1:
                    issues.append("Production memory below 10% available")
    prod_logs = values["prod_gateway"]
    stopped = last_matching(prod_logs, "restarting (reason: stopped)")
    polling = last_matching(prod_logs, "isolated polling worker poll-start")
    prod = "Telegram polling" if polling and now - polling < 120 and polling > (stopped or 0) else (
        "Telegram recovering" if stopped and now - stopped < 1800 else "Unknown")
    try:
        accounts = json.loads(values["prod_channel"] or "{}").get("channelAccounts", {}).get("telegram", [])
        account = next((row for row in accounts if row.get("accountId", "default") == "default"), {})
        if account.get("running") is True and account.get("connected") is True:
            prod = "Telegram connected"
    except (ValueError, TypeError):
        pass
    if prod == "Telegram recovering":
        issues.append("Production Telegram listener is stopping repeatedly")
    elif prod == "Unknown":
        # Lack of a recent failure is not evidence of a working inbound listener.
        issues.append("Production Telegram response not verified")
    dev_state = (values["dev_gateway"] or "").strip()
    dev = "Running" if dev_state == "running healthy" else (
        "Starting" if dev_state == "running starting" else "Unknown")
    if dev == "Unknown":
        issues.append("DEV gateway health unavailable")
    if "embedded run timeout" in (values["dev_logs"] or ""):
        issues.append("DEV AI response timed out")
    for role in ("prod", "dev"):
        failures = values[f"{role}_failed"]
        if failures is None:
            issues.append(f"{role.upper()} service health unavailable")
        elif "openclaw-mailmanager-summary.service" in failures:
            issues.append("Gmail authorization missing")
        elif any("openclaw" in line for line in failures.splitlines()):
            issues.append(f"{role.upper()} service failure")
        disks = values[f"{role}_disk"]
        if disks is None:
            issues.append(f"{role.upper()} storage health unavailable")
        else:
            for line in disks.splitlines()[1:]:
                fields = line.split()
                if len(fields) >= 6 and re.fullmatch(r"\d+%", fields[-2]):
                    if int(fields[-2][:-1]) >= 90:
                        issues.append(f"{role.upper()} storage above 90%")
            if role == "prod" and "/mnt/ai-storage" not in disks:
                issues.append("Production backup storage unavailable")
    prod_backup = backup_label(last_matching(values["prod_backup"], "Automatic backup status: completed"), now, 2 * 86400)
    dev_backup = backup_label(last_matching(values["dev_backup"], "FULL DEV BACKUP COMPLETE"), now, 8 * 86400)
    for role, label in (("Production", prod_backup), ("DEV", dev_backup)):
        if not label.startswith("Current"):
            issues.append(f"{role} backup {label.lower()}")
    m4 = "Unknown"
    try:
        sample = feed.get("m4", {}) if ENVIRONMENT == "prod" else json.loads((STATE / "m4.json").read_text())
        if 0 <= now - sample["checked_epoch"] <= 3600:
            stamp = sample.get("last_destination_backup_epoch")
            m4 = backup_label(stamp, now, 36 * 3600)
            if sample.get("running"):
                m4 += "; running"
            if not sample.get("latest_lookup_ok", True):
                issues.append("M4 latest backup lookup unavailable")
    except (OSError, ValueError, KeyError, TypeError):
        pass
    if not m4.startswith("Current"):
        issues.append("M4 destination backup freshness unverified" if m4.startswith("Unknown") else "M4 backup overdue")
    report = {
        "checked_epoch": now,
        "observations": {"checked_epoch": now, "values": {
            key: value for key, value in values.items() if key.startswith("dev_") and key != "dev_logs"
        }, "m4": sample if "sample" in locals() else {}},
        "text": "\n".join([
            f"System health | {datetime.fromtimestamp(now, ZONE):%b %d %H:%M} CT",
            "Attention" if issues else "OK",
            f"Production: {prod} | DEV: {dev}",
            f"Production backup: {prod_backup}",
            f"DEV backup: {dev_backup}",
            f"M4 Time Machine: {m4}",
            "Problems: " + ("; ".join(dict.fromkeys(issues)) if issues else "None"),
        ]),
    }
    return report


def save(report):
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = STATE / "report.json.tmp"
    temp.write_text(json.dumps(report))
    temp.replace(STATE / "report.json")


def send(report, chat_id):
    """Use DEV's existing token; never print credentials or request URLs."""
    config = json.loads((CONFIG_DIR / "openclaw.json").read_text())
    token = config["channels"]["telegram"]["botToken"]
    if not isinstance(token, str) or not token:
        raise ValueError("DEV Telegram token unavailable")
    payload = urllib.parse.urlencode({"chat_id": chat_id, "text": report["text"]}).encode()
    request = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage", data=payload)
    with urllib.request.urlopen(request, timeout=15) as response:
        result = json.load(response)
    if not result.get("ok"):
        raise ValueError("Telegram delivery rejected")
    return result["result"]["message_id"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--send", action="store_true")
    parser.add_argument("--chat-id")
    args = parser.parse_args()
    if args.send and not args.chat_id:
        parser.error("--send requires --chat-id")
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STATE / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        report = collect()
        save(report)
        if not args.send:
            print(report["text"])
            return
        ledger = STATE / "delivery.json"
        day = datetime.now(ZONE).strftime("%Y-%m-%d")
        previous = json.loads(ledger.read_text()) if ledger.exists() else {}
        if previous.get("day") == day:
            print("Daily message already attempted; duplicate suppressed")
            return
        # Persist before the network call: an ambiguous timeout must not duplicate a message.
        ledger.write_text(json.dumps({"day": day, "status": "pending"}))
        try:
            message_id = send(report, args.chat_id)
        except Exception:
            print("Telegram delivery failed or uncertain; credentials omitted")
            raise SystemExit(1)
        ledger.write_text(json.dumps({"day": day, "status": "sent", "message_id": message_id}))
        print(f"{ENVIRONMENT.upper()} daily health message delivered (message {message_id})")


if __name__ == "__main__":
    main()
