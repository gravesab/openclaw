#!/usr/bin/env python3
"""collect_trends.sh must not SSH to remote storage unless a host is named.

The storage host used to default to the PROD host. curl, ssh, docker, and
findmnt are stubbed on PATH and HOME is a temp dir, so the run makes no network
calls and writes only inside the temp dir.
"""

from __future__ import annotations

import csv
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name("collect_trends.sh")

STUBS = {
    # Records every ssh invocation; prints nothing so samples stay empty.
    "ssh": '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$SSH_CALLS_FILE"\n',
    "curl": "#!/usr/bin/env bash\nexit 7\n",
    "docker": "#!/usr/bin/env bash\nexit 0\n",
    # /mnt/ai-storage is never mounted here, forcing the remote branch.
    "findmnt": "#!/usr/bin/env bash\nexit 1\n",
}


class CollectTrendsStorageHostTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.home = root / "home"
        self.home.mkdir()
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name, body in STUBS.items():
            stub = bin_dir / name
            stub.write_text(body, encoding="utf-8")
            stub.chmod(0o755)
        self.ssh_calls = root / "ssh_calls.txt"
        self.env = {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOME": str(self.home),
            "SSH_CALLS_FILE": str(self.ssh_calls),
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_script(self, **extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env={**self.env, **extra},
            capture_output=True,
            text=True,
            timeout=60,
        )

    def storage_ssh_calls(self) -> list[str]:
        if not self.ssh_calls.exists():
            return []
        return [c for c in self.ssh_calls.read_text(encoding="utf-8").splitlines() if "/mnt/ai-storage" in c]

    def last_row(self) -> dict[str, str]:
        trend = self.home / "ai/projects/openclaw/reports/trends.csv"
        with trend.open(newline="") as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(len(rows), 1)
        return rows[0]

    def test_no_storage_ssh_without_explicit_host(self) -> None:
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.storage_ssh_calls(), [])
        self.assertEqual(self.last_row()["external_disk_used_pct"], "")

    def test_storage_ssh_uses_only_the_named_host(self) -> None:
        result = self.run_script(OPENCLAW_INTELMINI_STORAGE_HOST="storage-host.invalid")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.storage_ssh_calls()
        self.assertEqual(len(calls), 1, calls)
        self.assertIn("@storage-host.invalid ", calls[0])


if __name__ == "__main__":
    unittest.main()
