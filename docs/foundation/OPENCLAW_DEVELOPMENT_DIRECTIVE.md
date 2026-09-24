---
title: "OpenClaw Development Directive"
summary: "Development governance and Apple-first application and intelligence direction."
read_when:
  - Planning native Apple features or AI model integration
  - Preparing Codex or Cursor implementation handoffs
version: "1.0"
status: "Foundational"
owner: "OpenClaw Operator"
last_reviewed: "2026-09-24"
category: "Governance"
source_document: "OPENCLAW_DEVELOPMENT_DIRECTIVE.md"
---

# OpenClaw Development Directive

Thank you for yesterday’s hard work. Before continuing, I want to reaffirm the
operating rules and long-term vision for this project.

All development must occur exclusively in the development environment and on
the `development` branch. Nothing may be moved to production until the work has
been fully implemented, tested, reviewed, and proven reliable. Production
deployment requires my explicit approval after I have personally tested and
accepted the developed application. Approval to develop, test, commit, or push
to `development` is not approval to deploy to production.

## Apple-first application and intelligence direction

The standing product direction is to maximize Apple Intelligence and the Apple
ecosystem. RanchOS presents a native Swift/SwiftUI application on iOS/iPadOS and
macOS, with one RanchOS application per platform and compiled domain modules.
Preserve the existing tvOS scope with platform-appropriate interactions. Design
navigation, accessibility, voice input, review flows, and system integration for
each Apple platform rather than making a browser dashboard the default product
experience. Operational dashboards remain supporting tools.

Evaluate public Apple frameworks first for each relevant feature. The
[Foundation Models framework](https://developer.apple.com/documentation/FoundationModels)
provides model capabilities, while
[App Intents](https://developer.apple.com/documentation/appintents) exposes app
actions and content to supported system experiences. These are integration
opportunities, not a claim that every Apple Intelligence feature has a public
API or is available on every target device.

OpenClaw coordinates supporting models and tools behind the native experience.
RanchBrain supplies authorized knowledge and reasoning support; domain services
retain their record ownership, authorization, validation, and confirmation
contracts. An on-device model or App Intent must use those same domain contracts
and must not become a second authority for identity, tenancy, or writes.

Evaluate capable open-source and local models, including Apple Silicon execution,
alongside suitable Apple capabilities. Select by measured task quality, privacy,
latency, reliability, memory use, and cost. Prefer on-device processing when it
meets the task requirements. Distinguish processing on the user's device from
processing on a separate local server and from cloud processing. A local model
running on Apple hardware is not, by that fact alone, an Apple Intelligence
integration. Keep provider-specific behavior in the owning plugin or adapter.

When a capability is unavailable, retain useful manual workflows and explain
the limitation. Use only approved, privacy-compatible model fallbacks; when none
is suitable, return an explicit unavailable result. Never silently move private
data to a remote provider. Ordinary workflows should not require users to choose
models unless the choice helps them make a meaningful decision.

### Required feature-design evidence

Each relevant design and Codex or Cursor implementation handoff must record:

1. The native Apple user journey and affected platforms.
2. The Apple Intelligence or framework opportunity, with current official Apple
   API documentation and SDK, OS, device, language, entitlement, and runtime
   availability checks. Explain a decision not to use an applicable capability.
3. What runs on-device, on an approved local server, or remotely; the supporting
   model choice and task-specific comparative evidence.
4. Data-access and confirmation boundaries, plus behavior when intelligence is
   disabled, unsupported, unavailable, offline, or fails during execution.
5. Validation on representative supported devices, including fallback behavior,
   accessibility, latency, and resource use. Build and simulator results must be
   distinguished from signed physical-device proof.

This section records product direction approved on September 24, 2026. It does
not assert that Apple Intelligence integration is implemented or activate model
routing. DEV implementation, device installation, runtime activation, and
Production deployment retain their existing separate authorization gates.

## Property-management requirements

The application must eventually provide a dependable, unified system for asset
and property management. This includes integration with a Swift application
currently being developed in Cursor. The Swift application will allow me to
enter and manage assets using an iPhone as the primary front end.

The iPhone experience must support fast, natural interaction through:

- Voice input
- Quick-selection controls
- Simple asset creation and updates
- Easy access to maintenance information
- Clear review and approval workflows

The system must also process equipment manuals and other PDFs using approved
open-source AI models. It should extract useful, evidence-backed information
such as:

- Preventive-maintenance tasks and schedules
- Oil and fluid specifications
- Filter and replacement-part information
- Wrench and fastener sizes
- OEM part numbers
- Service intervals
- Capacities, tolerances, and torque specifications
- Safety warnings and operating procedures

Extracted information must remain traceable to its source document, page, and
relevant passage whenever possible. The system must clearly distinguish
verified source information from AI inference, uncertain findings, and missing
information. It must never fabricate specifications, part numbers, maintenance
requirements, or completed actions.

Reliability and usability are primary requirements. The application should be
intuitive enough for quick daily use while maintaining strong validation, audit
history, error handling, rollback protection, and data integrity. Important
actions must be reviewable, and potentially consequential changes must remain
under operator control.

Structured application data, asset records, workflow state, approvals, audit
history, and reference-document metadata must use PostgreSQL as the
authoritative store. Large source artifacts—including PDFs, notes, photographs,
manuals, invoices, and related reference files—must be stored on the external
4 TB drive attached to the Intel Mini. PostgreSQL records must retain each
artifact's storage path, content checksum, source identity, and evidence
metadata. Uploads must use validation, duplicate detection, temporary staging,
checksum verification, and atomic final placement so an interrupted operation
cannot present a partial file as complete.

The overall objective is a trustworthy, easy-to-use platform that turns voice
input, quick selections, asset records, manuals, and maintenance history into
accurate and actionable property-management information.

Development priorities should remain:

1. Correctness and safety
2. Source traceability and evidence
3. Reliability and data integrity
4. Simple, efficient user experience
5. Development testing and operator acceptance
6. Production deployment only after explicit approval
7. Keeping GitHub’s `development` and `production` branches current within
   their approved boundaries

Updating GitHub’s `development` branch is part of normal development. The
`production` branch may only be updated after explicit operator testing,
acceptance, and production authorization. Updating `development` never implies
permission to update or deploy `production`.

These principles govern all future architecture, implementation, testing,
documentation, and deployment decisions for this project.
