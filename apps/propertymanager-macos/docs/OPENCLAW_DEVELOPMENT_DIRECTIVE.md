---
description: OpenClaw/PropertyManager development directive — DEV only, evidence, no fabrication, no prod without approval
alwaysApply: true
---

# OpenClaw Development Directive

- Develop only in development environments. This Swift app work stays on the M4. OpenClaw code stays on UTM openclawdev / development branch. Never implement ongoing work against Intel Mini production.
- No production deployment or production OpenClaw changes without explicit operator approval after personal testing/acceptance. Dev commits are not prod approval.
- Keep GitHub DEV and PROD separate and accurate.
- iPhone-first UX goals: voice, quick-select, simple asset CRUD, maintenance access, review/approval.
- Manual/PDF extraction uses approved open-source models only. Capture PM tasks, fluids, filters, parts, wrench/fastener sizes, OEM part numbers, intervals, capacities/tolerances/torque, safety/procedures.
- Evidence required: source document, page, and passage when possible. Label verified vs inferred vs uncertain vs missing. Never fabricate specs, part numbers, maintenance needs, or completed actions.
- Priorities: correctness/safety → source traceability → reliability → simple UX → tested acceptance → production only with explicit approval.
- Canonical copy: Intel Mini ranchbrain/Foundation/OpenClaw-Development-Directive.md
