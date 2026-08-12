from __future__ import annotations

import subprocess
import unittest
from unittest import mock

from tools.dashboard import m4_metrics_helper


class M4MetricsHelperTests(unittest.TestCase):
    def test_collects_fixed_read_only_metrics(self):
        outputs = {
            ("/usr/bin/vm_stat",): (
                "Mach Virtual Memory Statistics: (page size of 4096 bytes)\n"
                "Pages free: 100.\nPages speculative: 20."
            ),
            ("/usr/sbin/sysctl", "-n", "hw.memsize"): str(1024**3),
            ("/bin/ps", "-p", "42", "-o", "%cpu="): "1.5",
            ("/usr/bin/uptime",): "up 1 day",
        }

        def output(command):
            return outputs[tuple(command)]

        process = subprocess.CompletedProcess([], 0, stdout="42\n", stderr="")
        with (
            mock.patch.object(m4_metrics_helper, "command_output", side_effect=output),
            mock.patch.object(m4_metrics_helper.subprocess, "run", return_value=process),
        ):
            result = m4_metrics_helper.collect_metrics()

        self.assertEqual(result["memory_total_gib"], "1.0")
        self.assertEqual(result["ollama_process"], "Running")
        self.assertEqual(result["ollama_cpu"], "1.5%")
        self.assertEqual(result["uptime"], "up 1 day")

    def test_command_surface_is_fixed(self):
        expected = {
            ("/usr/bin/vm_stat",),
            ("/usr/sbin/sysctl", "-n", "hw.memsize"),
            ("/bin/ps", "-p", "42", "-o", "%cpu="),
            ("/usr/bin/uptime",),
        }
        commands = []

        def output(command):
            commands.append(tuple(command))
            if command[0] == "/usr/bin/vm_stat":
                return "page size of 4096 bytes\nPages free: 1."
            if command[0] == "/usr/sbin/sysctl":
                return str(1024**3)
            return "0"

        process = subprocess.CompletedProcess([], 0, stdout="42\n", stderr="")
        with (
            mock.patch.object(m4_metrics_helper, "command_output", side_effect=output),
            mock.patch.object(
                m4_metrics_helper.subprocess, "run", return_value=process
            ) as run,
        ):
            m4_metrics_helper.collect_metrics()

        self.assertEqual(set(commands), expected)
        run.assert_called_once_with(
            ["/usr/bin/pgrep", "-f", "[o]llama"],
            check=False,
            capture_output=True,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
