#!/usr/bin/env python3
"""Tests for the Ranch OS PROD-target guard."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_prod_targets as guard  # noqa: E402

PATTERNS = ["(?<![0-9.])100\\.85\\.36\\.72(?![0-9])", "\\bintelmini\\b"]
# The exact default removed from save_mac_cache_to_api.sh (GAP_ANALYSIS.md P0-1).
OLD_PROD_DEFAULT = 'API_BASE="${PROPERTYMANAGER_API_BASE:-http://intelmini:5062}"\n'


def allowlist(*entries: dict) -> guard.Allowlist:
    return guard.load_allowlist({"patterns": PATTERNS, "entries": list(entries)})


def entry(path: str, count: int, status: str = "intended") -> dict:
    return {"path": path, "count": count, "status": status, "reason": "test"}


class EvaluateTests(unittest.TestCase):
    def test_exact_match_passes(self) -> None:
        self.assertEqual(guard.evaluate({"a.sh": 2}, allowlist(entry("a.sh", 2))), [])

    def test_unlisted_file_fails(self) -> None:
        problems = guard.evaluate({"new_tool.sh": 1}, allowlist())
        self.assertEqual(len(problems), 1)
        self.assertIn("not in the allowlist", problems[0])

    def test_higher_count_fails(self) -> None:
        problems = guard.evaluate({"a.sh": 3}, allowlist(entry("a.sh", 2)))
        self.assertIn("permits 2", problems[0])

    def test_lower_count_fails_so_list_stays_exact(self) -> None:
        problems = guard.evaluate({"a.sh": 1}, allowlist(entry("a.sh", 2)))
        self.assertIn("lower the entry", problems[0])

    def test_stale_entry_fails(self) -> None:
        problems = guard.evaluate({}, allowlist(entry("gone.sh", 1)))
        self.assertIn("remove the entry", problems[0])


class AllowlistValidationTests(unittest.TestCase):
    def test_rejects_bad_entries(self) -> None:
        bad = [
            {"patterns": []},
            {"patterns": PATTERNS, "entries": [entry("a.sh", 0)]},
            {"patterns": PATTERNS, "entries": [entry("a.sh", 1, status="ok")]},
            {"patterns": PATTERNS, "entries": [{**entry("a.sh", 1), "reason": " "}]},
            {"patterns": PATTERNS, "entries": [entry("a.sh", 1), entry("a.sh", 1)]},
            {"patterns": PATTERNS, "entries": [{**entry("a.sh", 1), "count": True}]},
        ]
        for raw in bad:
            with self.subTest(raw=raw), self.assertRaises(guard.AllowlistError):
                guard.load_allowlist(raw)

    def test_repo_allowlist_is_valid(self) -> None:
        raw = json.loads(guard.ALLOWLIST_PATH.read_text(encoding="utf-8"))
        loaded = guard.load_allowlist(raw)
        self.assertTrue(loaded.entries)


class ScanTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.patterns = guard.load_allowlist({"patterns": PATTERNS}).patterns

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, rel: str, content: bytes | str) -> str:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, str):
            content = content.encode("utf-8")
        path.write_bytes(content)
        return rel

    def test_catches_the_removed_prod_default(self) -> None:
        rel = self.write("tools/x/save.sh", OLD_PROD_DEFAULT)
        counts = guard.scan(self.root, [rel], self.patterns)
        self.assertEqual(counts, {rel: 1})
        self.assertTrue(guard.evaluate(counts, allowlist()))

    def test_ignores_prose_binary_and_lookalikes(self) -> None:
        files = [
            self.write("README.md", "PROD is intelmini\n"),
            self.write("docs/a.txt", "intelmini\n"),
            self.write("reports/r.txt", "100.85.36.72\n"),
            self.write("CHANGELOG.txt", "intelmini\n"),
            self.write("bin/blob.dat", b"\0intelmini"),
            self.write("tools/ok.py", "path = 'log_from_intelmini.csv'\nhost = '100.85.36.720'\n"),
            self.write("tools/ranchos_guard/fixtures.py", "HOST = 'intelmini'\n"),
        ]
        self.assertEqual(guard.scan(self.root, files, self.patterns), {})

    def test_counts_lines_not_occurrences(self) -> None:
        rel = self.write("a.py", "x = 'intelmini 100.85.36.72'\ny = 'intelmini'\n")
        self.assertEqual(guard.scan(self.root, [rel], self.patterns), {rel: 2})


class MainTests(unittest.TestCase):
    def test_main_fails_on_unlisted_reference_in_git_repo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "tool.sh").write_text(OLD_PROD_DEFAULT, encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "tool.sh"], check=True)
            result = subprocess.run(
                [sys.executable, str(Path(guard.__file__)), str(root)],
                capture_output=True,
                text=True,
                timeout=60,
                env={"PYTHONDONTWRITEBYTECODE": "1", "PATH": "/usr/bin:/bin"},
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("tool.sh: 1 PROD reference(s) not in the allowlist", result.stderr)


if __name__ == "__main__":
    unittest.main()
