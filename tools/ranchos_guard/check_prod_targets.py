#!/usr/bin/env python3
"""Fail when tracked code gains a reference to a Ranch OS PROD host.

Every existing reference must be listed in ``prod_targets_allowlist.json``
with its exact per-file line count, a reason, and a status (``intended`` or
``review``). The check fails on:

- a file with PROD references that is not in the allowlist;
- a file whose count is higher than allowed (a new PROD default); and
- a stale entry whose count is lower than allowed, so the list stays exact.

Prose (``*.md``, ``docs/``, ``reports/``, changelogs) is out of scope: it may
name PROD for documentation. Stdlib only; reads tracked files via ``git``.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path

ALLOWLIST_PATH = Path(__file__).resolve().with_name("prod_targets_allowlist.json")
# The guard's own files define the PROD patterns and their test fixtures; scanning
# them would make the guard fail on itself once they are tracked.
EXCLUDED_PREFIXES = ("docs/", "reports/", "changelog/", "tools/ranchos_guard/")
EXCLUDED_SUFFIXES = (".md",)
VALID_STATUSES = frozenset({"intended", "review"})


@dataclass(frozen=True)
class AllowEntry:
    path: str
    count: int
    status: str
    reason: str


@dataclass(frozen=True)
class Allowlist:
    patterns: tuple[re.Pattern[str], ...]
    entries: Mapping[str, AllowEntry]


class AllowlistError(ValueError):
    pass


def load_allowlist(raw: object) -> Allowlist:
    if not isinstance(raw, dict):
        raise AllowlistError("allowlist must be a JSON object")
    patterns = raw.get("patterns")
    if not isinstance(patterns, list) or not patterns or not all(isinstance(p, str) and p for p in patterns):
        raise AllowlistError("patterns must be a non-empty list of regex strings")
    entries: dict[str, AllowEntry] = {}
    for item in raw.get("entries") or []:
        if not isinstance(item, dict):
            raise AllowlistError("each entry must be an object")
        path, count = item.get("path"), item.get("count")
        status, reason = item.get("status"), item.get("reason")
        if not isinstance(path, str) or not path:
            raise AllowlistError("entry path must be a non-empty string")
        if not isinstance(count, int) or isinstance(count, bool) or count < 1:
            raise AllowlistError(f"{path}: count must be a positive integer")
        if status not in VALID_STATUSES:
            raise AllowlistError(f"{path}: status must be one of {sorted(VALID_STATUSES)}")
        if not isinstance(reason, str) or not reason.strip():
            raise AllowlistError(f"{path}: reason is required")
        if path in entries:
            raise AllowlistError(f"{path}: duplicate entry")
        entries[path] = AllowEntry(path, count, status, reason)
    return Allowlist(tuple(re.compile(p) for p in patterns), entries)


def in_scope(path: str) -> bool:
    lowered = path.lower()
    if lowered.endswith(EXCLUDED_SUFFIXES) or lowered.startswith(EXCLUDED_PREFIXES):
        return False
    return not Path(lowered).name.startswith("changelog")


def count_matches(text: str, patterns: Iterable[re.Pattern[str]]) -> int:
    compiled = tuple(patterns)
    return sum(1 for line in text.splitlines() if any(p.search(line) for p in compiled))


def evaluate(counts: Mapping[str, int], allowlist: Allowlist) -> list[str]:
    """Return human-readable violations; empty means the check passes."""
    problems: list[str] = []
    for path in sorted(counts):
        found = counts[path]
        entry = allowlist.entries.get(path)
        if entry is None:
            problems.append(f"{path}: {found} PROD reference(s) not in the allowlist")
        elif found > entry.count:
            problems.append(f"{path}: {found} PROD reference(s), allowlist permits {entry.count}")
        elif found < entry.count:
            problems.append(f"{path}: {found} PROD reference(s), allowlist says {entry.count}; lower the entry")
    for path in sorted(set(allowlist.entries) - set(counts)):
        problems.append(f"{path}: allowlisted but has no PROD references; remove the entry")
    return problems


def tracked_files(repo_root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files", "-z"],
        check=True,
        capture_output=True,
    )
    return [p for p in result.stdout.decode("utf-8").split("\0") if p]


def scan(repo_root: Path, files: Iterable[str], patterns: Iterable[re.Pattern[str]]) -> dict[str, int]:
    compiled = tuple(patterns)
    counts: dict[str, int] = {}
    for rel in files:
        if not in_scope(rel):
            continue
        path = repo_root / rel
        if not path.is_file() or path.is_symlink():
            continue
        data = path.read_bytes()
        if b"\0" in data[:8192]:
            continue  # binary
        found = count_matches(data.decode("utf-8", errors="replace"), compiled)
        if found:
            counts[rel] = found
    return counts


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    repo_root = Path(args[0]).resolve() if args else Path(__file__).resolve().parents[2]
    try:
        allowlist = load_allowlist(json.loads(ALLOWLIST_PATH.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, AllowlistError, re.error) as exc:
        print(f"prod-target guard: invalid allowlist: {exc}", file=sys.stderr)
        return 2
    counts = scan(repo_root, tracked_files(repo_root), allowlist.patterns)
    problems = evaluate(counts, allowlist)
    if problems:
        print("prod-target guard: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print(
            "A DEV tool must not default to a PROD host. If this reference is an intended PROD "
            f"client, add or update its entry in {ALLOWLIST_PATH.name} with a reason.",
            file=sys.stderr,
        )
        return 1
    review = sorted(e.path for e in allowlist.entries.values() if e.status == "review")
    print(f"prod-target guard: OK ({len(counts)} allowlisted file(s); {len(review)} marked for review)")
    for path in review:
        print(f"  review: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
