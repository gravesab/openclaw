#!/usr/bin/env python3
"""Emit the fixed, read-only macOS metrics payload used by the dashboard."""

from __future__ import annotations

import json
import re
import subprocess


def command_output(command: list[str]) -> str:
    return subprocess.check_output(command, text=True).strip()


def collect_metrics() -> dict[str, str]:
    result = {
        "memory_used_gib": "unknown",
        "memory_total_gib": "unknown",
        "memory_percent": "unknown",
        "ollama_process": "unknown",
        "ollama_cpu": "unknown",
        "uptime": "unknown",
    }

    try:
        vm = command_output(["/usr/bin/vm_stat"])
        total_bytes = int(command_output(["/usr/sbin/sysctl", "-n", "hw.memsize"]))
        page_match = re.search(r"page size of (\d+) bytes", vm)
        if page_match is None:
            raise ValueError("vm_stat page size unavailable")
        values: dict[str, int] = {}
        for line in vm.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            number = re.search(r"(\d+)", value.replace(".", ""))
            if number:
                values[key.strip()] = int(number.group(1))
        free_pages = values.get("Pages free", 0) + values.get(
            "Pages speculative", 0
        )
        used_bytes = total_bytes - free_pages * int(page_match.group(1))
        used_gib = used_bytes / 1024**3
        total_gib = total_bytes / 1024**3
        result.update(
            memory_used_gib=f"{used_gib:.1f}",
            memory_total_gib=f"{total_gib:.1f}",
            memory_percent=f"{used_gib / total_gib * 100:.0f}%",
        )
    except Exception as error:
        result["memory_error"] = str(error)

    try:
        process = subprocess.run(
            ["/usr/bin/pgrep", "-f", "[o]llama"],
            check=False,
            capture_output=True,
            text=True,
        )
        pids = process.stdout.split()
        result["ollama_process"] = "Running" if pids else "Not running"
        result["ollama_cpu"] = (
            command_output(["/bin/ps", "-p", pids[0], "-o", "%cpu="]) + "%"
            if pids
            else "0%"
        )
    except Exception as error:
        result["process_error"] = str(error)

    try:
        result["uptime"] = command_output(["/usr/bin/uptime"])
    except Exception as error:
        result["uptime_error"] = str(error)

    return result


if __name__ == "__main__":
    print(json.dumps(collect_metrics(), separators=(",", ":")))
