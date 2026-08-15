---
title: "OpenClaw Operations Runbook"
version: "1.1"
status: "Foundational"
owner: "OpenClaw Architecture"
last_reviewed: "2026-07-26"
category: "Operations"
source_document: "OPERATIONS_RUNBOOK.md"
---

# OpenClaw Operations Runbook

Version: 1.1
Status: Foundational
Owner: OpenClaw Architecture
Last Updated: 2026-07-26

---

# Purpose

This runbook defines the standard operating procedures for administering OpenClaw.

Its goals are to:

- provide repeatable operational procedures
- reduce recovery time
- improve consistency
- support both human operators and AI assistants

---

# Daily Operations

- Review Dashboard Health
- Review Backup Center
- Check watchdog status
- Review Daily Executive Briefing
- Confirm backup verification is healthy
- Investigate warnings before critical failures develop

---

# Weekly Operations

- Verify backup integrity
- Confirm restore verification reports
- Review disk utilization
- Review service health
- Review security updates
- Verify RanchBrain knowledge backups

---

# Monthly Operations

- Test a non-destructive restore preview
- Review foundational documentation
- Remove obsolete temporary files
- Audit AI logs
- Review backup retention
- Verify monitoring coverage

---

# Before Any Change

1. Confirm current Git branch
2. Review uncommitted changes
3. Create a backup if appropriate
4. Verify rollback strategy
5. Record significant architectural changes

---

# Incident Response

For any unexpected issue:

1. Assess impact
2. Preserve logs
3. Verify backups
4. Stabilize services
5. Restore only if necessary
6. Document root cause
7. Record lessons learned

---

# Service Recovery Order

1. PostgreSQL
2. Redis
3. OpenClaw services
4. Dashboard
5. PropertyManager API
6. Telegram integrations
7. RanchBrain services

---

# PropertyManager API WSGI Operations (development VM)

The PropertyManager REST API runs as the user service
`propertymanager-api.service`. Gunicorn is the WSGI master; Flask remains the
application framework. See
[PropertyManager API Development Runbook](PROPERTY_MANAGER_API_DEVELOPMENT_RUNBOOK.md)
for install, bind/port, worker policy, and acceptance checks.

Standard health checks:

```text
systemctl --user is-active propertymanager-api.service
systemctl --user status propertymanager-api.service
curl --fail http://127.0.0.1:5062/health
```

Recent logs:

```text
journalctl --user -u propertymanager-api.service -n 100 --no-pager
```

Graceful configuration reload:

```text
systemctl --user reload propertymanager-api.service
```

Controlled restart:

```text
systemctl --user restart propertymanager-api.service
```

Do **not** deploy or restart this stack on the production Intel Mini without
explicit operator approval. Direct Flask (`PROPERTYMANAGER_ALLOW_FLASK_DEV=1`)
is an emergency rollback path only.

---

# Dashboard WSGI Operations

The dashboard normally runs as the user service
`openclaw-dashboard.service`. Gunicorn is the WSGI master and supervises two
threaded workers.

Standard health checks:

```text
systemctl --user is-active openclaw-dashboard.service
systemctl --user status openclaw-dashboard.service
curl --fail http://127.0.0.1:5051/
```

Recent logs:

```text
journalctl --user -u openclaw-dashboard.service -n 100 --no-pager
```

Graceful configuration reload:

```text
systemctl --user reload openclaw-dashboard.service
```

Controlled restart:

```text
systemctl --user restart openclaw-dashboard.service
```

Before changing the service, preserve the installed unit, record the current
commit, and confirm the direct Flask rollback command is available. Production
changes still require operator testing and explicit deployment approval.

If the WSGI service cannot start:

1. Disable and stop `openclaw-dashboard.service`.
2. Restore the previous unit from the deployment rollback checkpoint.
3. As a temporary recovery measure only, start
   `.venv-dashboard/bin/python tools/dashboard/app.py`.
4. Confirm `http://127.0.0.1:5051/` returns HTTP 200.
5. Preserve Gunicorn and systemd logs before attempting another deployment.

The direct Flask server is a temporary rollback path, not an accepted steady
production state.

## Restricted remote host metrics

Optional remote memory, process, CPU, and uptime reporting uses a dedicated
Ed25519 key configured with `OPENCLAW_M4_SSH_KEY`. Do not reuse a backup,
deployment, interactive-login, or tunnel credential. Keep Development and
Production keys separate.

The remote authorization entry must use OpenSSH `restrict` and a forced command
that invokes only an installed copy of `tools/dashboard/m4_metrics_helper.py`.
The forced command
must not dispatch `$SSH_ORIGINAL_COMMAND`, accept arguments, start a shell, or
permit forwarding or a PTY. Install the dashboard environment variables from
`scripts/systemd/openclaw-dashboard-m4-metrics.conf.example`, then reload the
user service.

Validation must prove all of the following before promotion:

1. Requesting an arbitrary SSH command still returns only the fixed metrics
   JSON document.
2. The private key is mode `0600` and readable only by the dashboard account.
3. The dashboard reports memory, Ollama process/CPU, and uptime without exposing
   remote command output or key material.
4. Removing or rejecting the key fails closed as unavailable metrics without
   affecting the Ollama HTTP health check.
5. Production installation and dashboard reload have explicit operator
   authorization.

---

# Documentation Policy

Operational procedures should be updated whenever:

- architecture changes
- services are added
- recovery procedures change
- automation is introduced

Documentation is considered part of the system.

---

# Foundational Statement

Reliable systems are built through disciplined operations, not heroics.

Consistency is a feature.
