from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.ai_intelligence import gateway_bridge


class GatewayBridgeCredentialTests(unittest.TestCase):
    def test_explicit_env_file_is_used_for_database_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / "ai-intelligence-dev.env"
            env_file.write_text(
                "\n".join(
                    [
                        "OPENCLAW_DB_HOST=development-db",
                        "OPENCLAW_DB_PORT=5432",
                        "OPENCLAW_DB_NAME=openclaw_ai_dev",
                        "OPENCLAW_DB_USER=openclaw",
                        "OPENCLAW_DB_PASSWORD=test-only",
                    ]
                ),
                encoding="utf-8",
            )

            with (
                mock.patch.object(gateway_bridge, "CREDENTIALS_PATH", env_file),
                mock.patch.dict(os.environ, {}, clear=True),
            ):
                gateway_bridge.load_database_environment()

                self.assertEqual(
                    os.environ["OPENCLAW_DB_HOST"],
                    "development-db",
                )
                self.assertEqual(
                    os.environ["OPENCLAW_DB_NAME"],
                    "openclaw_ai_dev",
                )


if __name__ == "__main__":
    unittest.main()
