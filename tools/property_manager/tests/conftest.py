"""pytest guard for PropertyManager live-integration scripts.

These files are pytest-style module functions that call a running API (default
http://127.0.0.1:5062, the live DEV API on the DEV VM), run psql/docker against
a live database, or restart a systemd unit. unittest never collects them, but a
plain ``pytest tools/property_manager`` would. Keep them out of pytest unless an
operator opts in explicitly. Running them directly as scripts is unaffected.
"""

from __future__ import annotations

import os

LIVE_INTEGRATION_SCRIPTS = [
    "test_meter_delta.py",
    "test_phase1_meters.py",
    "test_phase2_meters.py",
    "test_restart_drain.py",
    "test_run_hours_trigger.py",
]

collect_ignore = (
    []
    if os.environ.get("PROPERTYMANAGER_LIVE_INTEGRATION") == "1"
    else list(LIVE_INTEGRATION_SCRIPTS)
)
