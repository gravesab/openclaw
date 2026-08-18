---
title: "GitHub Source of Truth and Re-creatability Policy"
version: "1.0"
status: "Foundational"
owner: "OpenClaw Architecture"
last_reviewed: "2026-08-18"
category: "Governance"
source_document: "GITHUB_SOURCE_OF_TRUTH_AND_RECREATABILITY_POLICY.md"
---

# GitHub Source of Truth and Re-creatability Policy

## Foundational Rule

Everything required to recreate OpenClaw shall be represented in GitHub.

No application, service, client, infrastructure component, operational script,
architecture specification, configuration contract, migration, test suite, or
required reconstruction knowledge may exist only on a developer machine.

GitHub is the authoritative source for recreatable project state.

## Required GitHub Content

The repository must contain, as applicable:

- application source code
- iOS source and project configuration
- macOS source and project configuration
- server and service source code
- RanchBrain and Ranch Operating System module source
- PropertyManager source
- Ranch Finance source
- Ranch Health source
- Ranch Energy source
- dashboards and user-interface source
- database schemas and migrations
- infrastructure definitions
- build scripts
- deployment scripts
- operational scripts
- tests and verification harnesses
- configuration templates
- API contracts
- architecture specifications
- foundational requirements
- disaster-recovery procedures
- reconstruction and bootstrap instructions

Future modules are governed by the same rule.

## Runtime Data and Secrets

GitHub shall not contain secret values, private credentials, live databases,
generated caches, transient build products, or other inappropriate runtime
artifacts.

Excluding an artifact from Git does not remove the recreatability requirement.

For every required external or runtime artifact, GitHub must contain enough
information to reconstruct, restore, reconnect, or validate it. This includes,
as appropriate:

- schema and migrations
- configuration templates
- expected storage locations
- restore procedures
- backup requirements
- content identity or checksums
- dependency versions
- bootstrap instructions
- validation procedures

## Large External Artifacts

Large or mutable artifacts may remain outside GitHub when Git is not an
appropriate storage mechanism. Examples include:

- virtual-machine disk images
- AI model weights
- equipment manuals and PDFs
- photographs
- videos
- database backups
- large binary archives

Their existence, authoritative location, required metadata, backup policy, and
restore or reacquisition procedure must be represented in GitHub.

## Local-Only Development Is Forbidden as a Final State

A working application or project component may not remain permanently outside
Git version control.

Local development directories are temporary working locations only.

When a component becomes part of OpenClaw, its required source and
reconstruction material must be brought under the governed Git repository.

This explicitly includes standalone Swift applications and other components
that were initially created outside the OpenClaw repository.

## Production Gate

No component may be promoted to production unless the source, configuration
contract, migrations, tests, and reconstruction instructions required for that
component are already committed to governed Git history.

Production must never depend on an uncommitted local-only implementation.

## Disaster Recovery Objective

Loss of the primary Mac must not result in loss of the OpenClaw project.

GitHub, together with approved external backups and documented secret/runtime
recovery procedures, must be sufficient to rebuild the project on replacement
hardware.

## Governance

This policy is foundational and applies to all current and future OpenClaw
modules, clients, services, environments, documentation, and infrastructure.

Implementation must never contradict this policy.
