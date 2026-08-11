---
title: "OpenClaw Foundational Documentation"
version: "1.0"
status: "Foundational"
owner: "OpenClaw Architecture"
last_reviewed: "2026-07-19"
category: "Index"
source_document: "FOUNDATIONAL_DOCUMENTS.md"
---

# OpenClaw Foundational Documentation

Version: 1.0
Status: Foundational
Owner: OpenClaw Architecture
Last Updated: 2026-07-19

---

# Purpose

This document is the master index for the foundational documentation that defines the OpenClaw platform.

Every major architectural decision should be documented in one of the referenced documents below rather than duplicated elsewhere.

This document serves as the starting point for developers, operators, and AI agents.

---

# Guiding Principles

- Local-first whenever practical.
- Safety before automation.
- Verify before trusting.
- Recover before replacing.
- Documentation is part of the product.
- AI assists but does not bypass governance.

---

# Foundation Library

## Project Vision

PROJECT_OVERVIEW.md

Defines the mission, scope, and long-term direction of OpenClaw.

---

## Architecture

RANCHBOT_ARCHITECTURE.md

Defines system architecture, service relationships, routing, and component responsibilities.

SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1.md

Defines the server-enforced boundary for proposals, authoritative mutations,
confirmation, concurrency, idempotency, and atomic audit evidence.

CANONICAL_CONFIRMATION_POLICY_V1.md

Defines confirmation classifications, the canonical operation matrix,
server-generated challenges, and single-use confirmation records.

ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1.md

Defines the atomic transaction boundary for authoritative mutation, audit,
confirmation consumption, idempotency, concurrency, and post-commit delivery.

AUTHORITATIVE_MUTATION_THREAT_MODEL_V1.md

Defines mutation-specific threats, protected assets, trust boundaries,
fail-closed security requirements, and implementation-independent tests.

AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1.md

Defines human and service identity, capabilities, delegation, revocation,
environment separation, and accountable authority for mutations.

AUTHORITATIVE_MUTATION_PROTOCOL_V1.md

Defines the complete server-enforced proposal, authorization, confirmation,
validation, concurrency, idempotency, transaction, result, and recovery lifecycle.

EXTERNAL_AUTHORITY_ANCHOR_AND_TRUST_ROOT_SPECIFICATION_V1.md

Defines the external authority anchor, signed trust-root artifacts, verification,
lifecycle, rotation, revocation, anti-rollback, audit, and recovery requirements.

AUTHORITY_ANCHOR_CEREMONY_CUSTODY_ROTATION_AND_RECOVERY_PROFILE_V1.md

Defines authority-anchor ceremony planning, custody, rotation, revocation,
recovery, evidence, environment separation, and fail-closed abort requirements.

AUTHORITY_ANCHOR_CRYPTOGRAPHIC_AND_CANONICALIZATION_PARAMETER_PROFILE_V1.md

Defines authority-anchor algorithms, canonical serialization, signatures,
digests, encodings, domain separation, compatibility, and downgrade prevention.

AUTHORITY_ANCHOR_IMMUTABLE_NON_SECRET_COMPATIBILITY_VECTOR_SPECIFICATION_V1.md

Defines immutable non-secret vectors, provenance, canonical expected results,
failure decisions, cross-platform conformance, and vector-set change control.

AUTHORITY_ANCHOR_IMPLEMENTATION_ASSURANCE_AND_APPROVED_CRYPTOGRAPHIC_LIBRARY_PROFILE_V1.md

Defines implementation assurance, evidence, approval units, supply-chain and
platform controls, validation, lifecycle, and fail-closed library governance.

CANDIDATE_LIBRARY_EVIDENCE_AND_COMPARATIVE_ASSESSMENT_SPECIFICATION_V1.md

Defines candidate evidence identity, provenance, comparison, uncertainty,
decision separation, reassessment, and fail-closed assessment requirements.

CANDIDATE_ASSESSMENT_EVIDENCE_RECORD_CANONICALIZATION_AND_INTEGRITY_PROFILE_V1.md

Defines evidence-record schemas, canonical bytes, content identities, provenance,
manifests, verification, redaction, and fail-closed integrity requirements.

---

## Web Runtime Standards

PYTHON_WEB_RUNTIME_INVENTORY.md

Inventories Python web applications, records their WSGI or ASGI deployment
status, and defines the development-first migration and reliability gates.

---

## Operational Philosophy

SOUL.md

Defines the long-term philosophy, values, and operating principles of OpenClaw.

---

## Development Governance

OPENCLAW_DEVELOPMENT_DIRECTIVE.md

Defines the mandatory development-only workflow, operator acceptance gate,
product reliability requirements, mobile asset-management vision, evidence
standards, and production authorization boundary.

---

## PropertyManager

PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md

Defines PropertyManager asset and meter policy, Phase 0 implementation gate,
dev-vs-production deployment phases, audit requirements, API reliability
contract, QR security, RanchBrain matching rules, and the pre-production test
matrix. Pairs with PROPERTY_MANAGER_ASSET_ARCHITECTURE.md under architecture/.

---

## Disaster Recovery

RESTORE_MANIFEST.md

Authoritative specification governing all backup verification, restore operations, rollback behavior, and disaster recovery.

---

## Dashboard

DASHBOARD_REPORT.md

Documents the Backup & Recovery Center and dashboard architecture.

---

## Engineering

TOOLS.md

Documents engineering tools, workflows, utilities, and development practices.

---

## AI Knowledge

PROJECT_CONTEXT.md

Provides project context for AI assistants and development sessions.

---

## RanchBrain

knowledge/
ranchbrain/

Authoritative knowledge repository for property management, operational procedures, and institutional memory.

---

# Governance Rules

Foundational documents should:

- describe policy rather than implementation
- avoid duplication
- remain stable over time
- be version controlled
- be reviewed before major architectural changes

---

# Document Hierarchy

Mission
↓
Architecture
↓
Governance
↓
Implementation
↓
Operations

Implementation must never contradict governance.

---

# Change Control

Changes to foundational documents should accompany major architectural changes and be reviewed before implementation.

---

# Future Foundation Documents

Reserved for:

- Security Manifest
- AI Governance Manifest
- Coding Standards
- Service Contracts
- Database Standards
- API Standards
- Monitoring Standards
- Testing Standards
- Deployment Standards
- Operations Runbook
- Incident Response Guide
- Home Assistant Integration Guide

---

# Foundational Statement

A healthy system is built on shared understanding.

Documentation preserves that understanding across time, people, and AI systems.

---

# Canonical Documentation Locations

The maintained documentation library is located under `docs/`.

## Foundation

- `docs/foundation/FOUNDATIONAL_DOCUMENTS.md`
- `docs/foundation/PROJECT_OVERVIEW.md`
- `docs/foundation/SOUL.md`
- `docs/foundation/AI_GOVERNANCE_MANIFEST.md`
- `docs/foundation/OPENCLAW_DEVELOPMENT_DIRECTIVE.md`
- `docs/foundation/RESTORE_MANIFEST.md`
- `docs/foundation/OPERATIONS_RUNBOOK.md`
- `docs/foundation/PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md`

## Architecture Documents

- `docs/architecture/ATOMIC_AUTHORITATIVE_WRITE_AND_AUDIT_TRANSACTION_DESIGN_V1.md`
- `docs/architecture/AUTHORITATIVE_IDENTITY_SERVICE_IDENTITY_AND_DELEGATION_POLICY_V1.md`
- `docs/architecture/AUTHORITATIVE_MUTATION_PROTOCOL_V1.md`
- `docs/architecture/AUTHORITATIVE_MUTATION_THREAT_MODEL_V1.md`
- `docs/architecture/AUTHORITY_ANCHOR_CEREMONY_CUSTODY_ROTATION_AND_RECOVERY_PROFILE_V1.md`
- `docs/architecture/AUTHORITY_ANCHOR_CRYPTOGRAPHIC_AND_CANONICALIZATION_PARAMETER_PROFILE_V1.md`
- `docs/architecture/AUTHORITY_ANCHOR_IMMUTABLE_NON_SECRET_COMPATIBILITY_VECTOR_SPECIFICATION_V1.md`
- `docs/architecture/CANONICAL_CONFIRMATION_POLICY_V1.md`
- `docs/architecture/EXTERNAL_AUTHORITY_ANCHOR_AND_TRUST_ROOT_SPECIFICATION_V1.md`
- `docs/architecture/PROPERTY_MANAGER_ASSET_ARCHITECTURE.md`
- `docs/architecture/RANCHBOT_ARCHITECTURE.md`
- `docs/architecture/SERVER_ENFORCED_MUTATION_AND_PROPOSAL_CONTRACT_V1.md`
- `docs/architecture/DASHBOARD_REPORT.md`
- `docs/architecture/PYTHON_WEB_RUNTIME_INVENTORY.md`
- `docs/architecture/PROJECT_CONTEXT.md`
- `docs/architecture/TOOLS.md`

The root-level copies are migration sources and are not the future canonical locations.
