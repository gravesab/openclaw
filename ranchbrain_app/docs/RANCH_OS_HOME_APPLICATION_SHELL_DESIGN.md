# Ranch OS unified application and Home shell design

Status: Module-host contract approved for DEV planning only; implementation
gates remain
Scope: One RanchOS application per Apple platform, shared Home shell, and
application-navigation boundary
Last updated: 2026-09-17

Ranch OS is one application on each Apple platform: iPhone, iPad, Mac, and
Apple TV. A person installs and opens **RanchOS**, then selects an authorized
domain experience such as Property Manager, Livestock Management, Ranch
Finance, or My Health. Those experiences are compiled feature modules within
the RanchOS application, not separately installed launchers and not dynamically
downloaded applications.

Ranch OS Home is the tenant-safe shell and default root for those feature
modules. It presents only applications and summaries authorized for the active
ranch, makes ranch switching explicit, and coordinates typed in-process
navigation to a selected module. It does not own domain records, authenticate
users, grant capabilities, or provide a cross-application database or search
path.

This document is a design contract. It does not authorize authentication work,
database migrations, application implementation, Apple app targets,
static-shell code, local fixtures, target restructuring, compilation,
simulator or device work, repackaging an existing app, deployment, Production
configuration, or changes to an existing domain system of record.

## Required foundation

The shell consumes the shared OpenClaw-authoritative `VerifiedPrincipal` and
the Ranch OS-authoritative `TenantContext`. It must not introduce another
identity source, membership store, tenant resolver, role mapping, or service
credential.

Before returning Home content, the server must:

1. validate the deployed `VerifiedPrincipal` contract;
2. resolve the user's current active memberships from Ranch OS;
3. require an explicit authorized tenant selection when more than one active
   membership exists;
4. derive the current role and operation-specific capabilities; and
5. establish the transaction-local principal, environment, and tenant context
   required by the multi-tenancy design.

A client-provided tenant ID, application ID, route, badge count, deep link, or
cached screen is a request only. It is never proof of identity, membership, or
capability.

The approved single-ranch DEV bootstrap may select its one configured tenant
only after the principal and active membership have been resolved. The shell
must not apply that convenience when the principal has multiple active
memberships.

## Preserve domain ownership

The shell owns application discovery, shell navigation state, tenant-switch
coordination, handoff state, and shell audit events. It does not absorb or
duplicate domain authority.

| Domain                  | Authoritative ownership                                                                                                                                               | Shell boundary                                                                                                                                                  |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Property                | Property owns assets, facilities, equipment, meters, maintenance, work requests, and their authoritative workflows.                                                   | Home may display an authorized Property summary and launch Property. It must not query or mutate Property tables directly.                                      |
| Livestock               | Livestock Management owns animals, identifiers, lifecycle, veterinary care, livestock inputs, and operational-cost attribution.                                       | Home may display an authorized Livestock summary and launch Livestock. It must use the versioned Livestock read/query contract and must not infer animal state. |
| Finance                 | Ranch Finance is the canonical ledger for bills, payments, budgets, tax treatment, accounting entries, and financial reporting.                                       | Home may show only a Finance-authorized summary or launch target. It must not reproduce ledger entries or post financial activity.                              |
| Health                  | Ranch Health is human health only. It does not own animal or veterinary data.                                                                                         | Home must not reveal Health availability, badges, or summaries from tenant membership alone. A separately approved personal-privacy capability is required.     |
| RanchBrain and OpenClaw | RanchBrain provides authorized knowledge and read/query surfaces; OpenClaw provides the authoritative verified-principal boundary and shared orchestration contracts. | Neither may use Home to gain direct database, filesystem, cache, index, or unrestricted search access to a domain application.                                  |

Tenant membership alone is not sufficient authorization for future human
Health or personal Finance information. Until their per-user privacy contracts
are approved, Home must omit sensitive summaries and direct routes rather than
falling back to tenant-wide visibility.

## Tenant-safe application registry

`RanchOSAppRegistryV1` is the server-authoritative catalog of applications that
the shell can present. It has two layers:

- a platform application definition containing no tenant data; and
- a tenant-owned enablement record controlling whether that application is
  available for a specific tenant and environment.

The effective registry is computed for one validated `TenantContext`. It is
not a global list filtered only in the client.

### Platform application definition

Each definition contains:

| Field                     | Contract                                                                                                   |
| ------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `registry_version`        | Version of the registry response contract.                                                                 |
| `app_id`                  | Stable, non-secret application identifier such as `property` or `livestock`.                               |
| `display_name`            | Presentation label only; never an authority value.                                                         |
| `lifecycle_state`         | Controlled value: `planned`, `enabled`, `suspended`, or `retired`. Only `enabled` applications can launch. |
| `supported_surfaces`      | Controlled set such as `iphone`, `ipad`, `macos`, and `tvos`.                                              |
| `launch_audience`         | Exact signed-handoff audience accepted by the domain application.                                          |
| `route_contract_version`  | Version of the application's allowlisted route contract.                                                   |
| `summary_contract`        | Optional versioned, read-only summary contract owned by the domain application.                            |
| `required_capabilities`   | Capability expression evaluated by the server for visibility and launch.                                   |
| `icon_key`                | Approved presentation asset key; no arbitrary remote asset URL.                                            |
| `return_contract_version` | Version of the signed return-envelope contract.                                                            |

Definitions must not contain credentials, host filesystem paths, database
locations, unrestricted URLs, tenant-specific record identifiers, or client
code that can weaken authorization.

### Tenant enablement

Each tenant application enablement contains non-null `tenant_id`, `app_id`,
environment, status, availability window when applicable, and audit fields.
It is tenant-owned and must receive the same repository predicates, composite
foreign keys, RLS policies, cache namespace, and audit treatment as other
tenant-owned records.

An effective registry entry is returned only when all of these are true:

- the platform definition is enabled for the current surface;
- the application is enabled for the active tenant and environment;
- the active membership is valid; and
- the principal has the capability required to see at least one safe entry
  route.

The server returns already-authorized entries. Clients may reorder or group
those entries for presentation but must not synthesize entries, loosen
capabilities, or reuse a registry response after tenant context changes.

## Unified Swift application architecture

RanchOS uses one app target and one user-visible RanchOS icon for each Apple
platform family:

| Platform family | Product shape                 | Hub navigation                                                                                                                               |
| --------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| iPhone and iPad | One universal iOS RanchOS app | Home is the root. iPad can expose Home and authorized modules in a sidebar; iPhone presents the same destinations through an adaptive stack. |
| macOS           | One RanchOS app               | A persistent sidebar and window-scoped Home state host authorized modules.                                                                   |
| tvOS            | One RanchOS app               | Home is the focusable root. It presents only TV-supported modules and task-safe dashboard routes.                                            |

The module-host contract in this section is approved as the RanchOS DEV
planning direction. That approval selects the client boundary only; it does not
approve a target restructure, Apple app targets, static-shell code, local
fixtures, compilation, simulator or device work, authentication work, registry
service, signer, database migration, module implementation, deployment, or
Production change.

This is a product and packaging boundary, not a new cross-domain backend. The
RanchOS app contains a small shell plus statically linked Swift feature modules
that each retain their own domain models, API client, route definitions, and
authorization handling. The shell owns only:

- session presentation and the current `TenantContext` lifecycle;
- the authorized application registry and module selection;
- platform navigation chrome, ranch switching, and a safe return to Home; and
- context invalidation, sanitized shell telemetry, and app-wide accessibility
  or appearance preferences that contain no tenant data.

Each feature module owns its domain UI and domain-specific screen state. For
example, Property Manager owns its assets, maintenance, and work-request
screens; Livestock Management owns animal, care, identifier, lifecycle, feed,
and operational-cost screens; Ranch Finance owns ledger and reporting screens;
and the `health` module, presented as **My Health**, owns approved personal
user-health experiences. The module must call
its own authorized domain contract. It cannot obtain another module's
repository, API client, database connection, storage key, or unrestricted
navigation state from the shell.

The registry chooses a known, compiled module by `app_id`; it never selects
arbitrary Swift code, a remote bundle, a `WebView`, a custom URL, or an
executable document. An enabled registry entry can only select a module that
the installed RanchOS build declares as supported on that platform. Conversely,
a compiled module is not shown or entered unless the effective registry permits
it for the active tenant, capability set, environment, and platform.

### Module host contract

The shell provides a deliberately narrow host interface. A module receives a
fresh, immutable presentation context containing the authorized application ID,
surface, environment, correlation ID, and a revalidation-capable tenant
context reference. It returns only a typed shell outcome:

- remain in the module;
- return to Home with an allowlisted presentation status; or
- require fresh session or tenant resolution.

The module host must not expose a mutable global tenant singleton, a generic
cross-module router, raw handoff tokens, or a catch-all `Any` payload. Domain
routes are closed, versioned types owned by the destination module. The shell
can carry an opaque, allowlisted `resource_ref` to the destination, but the
destination must reauthorize it before rendering or mutating data.

An in-process module transition does not make authorization weaker. Before
opening a module, RanchOS validates the current effective registry and creates
a fresh route context. The module revalidates its destination route and every
domain request. If context changes, the shell discards the module's navigation
and tenant-bound view state, then returns to Home.

### Migration from separate applications

The existing standalone PropertyManager, Livestock, Finance, and TV fixtures
are source applications during migration, not additional launch targets in the
finished product. A module moves into RanchOS only after its domain contract,
authentication behavior, navigation, accessibility, and target platform proof
are independently accepted. Until then, its registry entry remains absent or
explicitly unavailable; the shell must not advertise an incomplete module or
silently deep-link into a separately installed app.

Removing a standalone app icon is a later packaging and data-migration
decision. It requires an approved per-module migration plan for local drafts,
notifications, widget or shortcut targets, documents, app-group/keychain data,
universal links, and a rollback or coexistence period. This design does not
authorize that removal.

### My Health module boundary

My Health is a compiled RanchOS module with the stable internal `app_id` of
`health`, its own domain routes, views, client, and privacy controls. It is the
signed-in user's own human-health experience. It never becomes a destination
for animal, veterinary, livestock-treatment, Property, Finance, or other
tenant-owned records.

Health has a stricter registry rule than ranch-operational modules. Tenant
membership never makes My Health visible, discoverable, launchable, or
summary-capable. The effective registry includes it only when the signed-in
person satisfies a separately approved personal-privacy capability and the
module is enabled for that exact platform and environment. Without that
capability, RanchOS omits the module entirely rather than showing an unavailable
tile, badge, placeholder, or route error that reveals its existence.

The first Health module increment must be read-only, personal-context-bound,
and explicitly scoped by a separate Health design. It starts on iPhone, iPad,
or macOS only after privacy, retention, notification, offline, and recovery
rules are approved. tvOS Health availability is not implied by the unified app
and remains absent until its own privacy and interaction review approves it.

## Capability-gated visibility

Visibility reduces accidental disclosure; the domain API remains the final
authorization boundary.

- An application tile is hidden when the user lacks its minimum visibility
  capability or when the application is unavailable to the active tenant.
- A tile may be visible while a specific action is absent when the user has
  read capability but lacks mutation capability.
- Badge counts and Home summaries come from bounded, versioned, read-only
  domain summary APIs. They must carry the active `TenantContext`, provenance,
  freshness, and an explicit unavailable or uncertain state.
- Home must not calculate badges by reading domain tables, shared search
  indexes, files, caches, notifications, or event streams directly.
- A hidden tile is not an authorization response. Direct route requests and
  stale clients must still be rejected by the shell and the target domain API.
- Authorization failures must not reveal whether another tenant has enabled an
  application or whether a referenced cross-tenant record exists.

Owner-only settings and membership controls are visible only with their exact
capabilities. A role label by itself must never activate a control.

## Explicit ranch switching

The active ranch is always visible in Home and persistent shell navigation.
The switcher lists only the caller's current active memberships and uses ranch
display names only for presentation.

Switching follows this sequence:

1. The client requests a target tenant from the authorized membership list.
2. The server reloads the principal lifecycle, membership, role, and required
   shell capability. It does not trust the displayed membership list as proof.
3. The server creates a new `TenantContext` and returns a new effective app
   registry for that tenant.
4. The client cancels in-flight domain requests, closes tenant-bound sheets and
   detail routes, and discards tenant-bound navigation and summary state.
5. Tenant-partitioned caches remain inaccessible under the new context; any
   non-partitioned shell cache is purged.
6. Home becomes the safe landing screen for the newly selected ranch.

The shell must never keep a Tenant A detail screen visible while presenting
Tenant B as active. Back navigation must not restore the prior tenant's screen
or snapshot. Unsaved domain drafts follow the owning application's policy, but
the shell must not silently move or resubmit a draft under another tenant.

A missing, stale, suspended, revoked, malformed, or ambiguous selection fails
closed. The prior authorized context may remain active only when the switch was
rejected before it changed; the UI must clearly state that no switch occurred.

## External route handoff

Normal Home-to-module navigation stays inside the RanchOS process and uses the
typed module-host contract. It does not use a URL scheme or client-created
handoff object. The destination module still receives fresh context and
reauthorizes its route and every domain request.

External entry paths, including HTTPS universal links, notifications, widgets,
shortcuts, restored activities, documents, and a temporary transition from an
older standalone application, use a signed, short-lived
`RanchOSAppHandoffV1` envelope. An arbitrary custom URL scheme, unsigned query
string, pasteboard value, or client-generated JSON object is not an
authoritative handoff.

The handoff contains only non-secret routing claims:

| Claim                          | Contract                                                                                                      |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| `version`                      | Exact supported handoff version.                                                                              |
| `issuer` and `audience`        | Approved shell issuer and exact target application audience.                                                  |
| `environment`                  | Exact DEV or Production binding; cross-environment use is denied.                                             |
| `principal_ref`                | Immutable, non-secret principal reference bound to the current verified session.                              |
| `tenant_id`                    | Tenant selected by Ranch OS after membership authorization. It is context to revalidate, not proof of access. |
| `app_id` and `requested_route` | Target application and allowlisted route identifier. No arbitrary URL or executable route.                    |
| `resource_ref`                 | Optional opaque domain-owned identifier. It conveys no read or mutation authority.                            |
| `correlation_id`               | End-to-end audit and troubleshooting identifier.                                                              |
| `state` and `nonce`            | Unpredictable values bound to the pending shell handoff and protected from replay.                            |
| `issued_at` and `expires_at`   | Short validity window under approved policy.                                                                  |
| `return_target`                | Exact allowlisted shell return target and return-contract version.                                            |

The envelope is signed by an approved environment-bound handoff signer whose
key is not available to clients or domain applications. Key custody, rotation,
algorithm selection, and Production trust establishment require separate
security approval; this document does not create those resources.

RanchOS must validate signature, issuer, audience, environment, version, time
window, nonce, state, route, and return target before creating a module route
context. The destination module must then resolve a fresh `TenantContext` and
reauthorize the requested route and resource against current membership and
capability. A valid signature never overrides revoked membership, suspended
application state, RLS, or domain authorization.

Accepted nonces are single-use. Replay, mutation, unknown versions, clock
failure, key failure, or validation ambiguity denies launch without opening a
cached domain screen.

## Signed return flow

A domain application returns through `RanchOSAppReturnV1`. The target
application signs the envelope with its approved environment-bound identity;
it does not reuse the shell signing identity.

The return contains the handoff correlation ID and state, source application,
environment, tenant ID, completion class, optional allowlisted Home route, and
issued/expiry times. It may carry an opaque result reference or a short
presentation-safe status code. It must not carry domain records, credentials,
database keys, filesystem paths, raw medical or financial data, or authority to
perform another mutation.

Home validates the signature, source audience, environment, state, nonce,
expiry, and pending-handoff record. It then reloads current membership and
capability before showing any tenant-owned summary or navigation target. A
return for a different tenant cannot switch ranch context automatically. Home
may offer an explicit authorized switch after independently resolving access.

A missing or invalid return leaves the domain mutation result unchanged. Home
shows a sanitized navigation failure and offers an authorized route back to
Home; it must not retry the domain mutation.

## Apple platform navigation

Every surface keeps the active ranch visible and uses the same registry,
handoff, return, and authorization contracts.

### iPhone

- Home is the safe root and shows the active ranch, authorized application
  tiles, and bounded domain summaries.
- The ranch switcher is reachable from the Home header and requires explicit
  confirmation when unsaved domain work exists.
- Domain applications own their internal tabs, sheets, and navigation stacks.
  Returning to Home does not expose another application's records.
- After a successful tenant switch, the navigation stack resets to Home.

### iPad

- A leading sidebar contains Home, the active ranch switcher, and authorized
  application entries.
- The detail region belongs to the selected domain application.
- Changing ranch closes tenant-bound detail and inspector state before loading
  the new registry.
- Multiwindow scenes bind to one explicit tenant context each. A scene must not
  inherit another scene's tenant merely because the same user opened it.

### macOS

- Persistent navigation shows Home, active ranch, and authorized applications.
- Each window has an explicit tenant context. New windows start at Home unless
  opened by a validated handoff.
- Restored windows must revalidate handoffs, membership, application
  availability, and routes before rendering tenant data.
- Desktop menus, keyboard shortcuts, notifications, widgets, and recent-item
  lists use the same capability and tenant checks as visible navigation.

### tvOS

- Home is the application root and uses a focusable grid of authorized,
  TV-supported modules. It shows no tile merely because that module exists on
  iPhone, iPad, or Mac.
- The active ranch is visible from Home and the global profile or switcher
  destination. A ranch switch returns to Home and clears the prior module's
  focus, navigation, and tenant-bound presentation state.
- A TV module must declare a remote-safe, large-target route set. Text-heavy
  administration, complex forms, and destructive or high-consequence mutation
  flows remain unavailable until their dedicated tvOS interaction design and
  domain authorization are approved.
- Siri, notifications, Top Shelf, restoration, and deep links are external
  entries and follow the same signed handoff and reauthorization path as every
  other platform.

Offline Home may show only a clearly marked, encrypted, tenant-partitioned
snapshot previously authorized for that same principal and tenant. It must not
switch tenants, launch a mutation, refresh a deep link, or infer current
membership while offline. Sensitive Health and Finance summaries are excluded
until their privacy and offline-retention policies are separately approved.

## Audit events

Shell audit events are append-only and carry environment, authorized tenant
when one exists, principal or service reference, membership reference,
operation, application, route class, outcome, reason code, correlation ID, and
event time. They must not store tokens, signatures, raw handoff envelopes,
medical or financial content, filesystem paths, or unnecessary presentation
attributes.

Required event classes include:

- `shell_registry_resolved` and `shell_registry_denied`;
- `tenant_switch_requested`, `tenant_switch_succeeded`, and
  `tenant_switch_denied`;
- `app_handoff_issued`, `app_handoff_accepted`, and `app_handoff_denied`;
- `app_return_accepted` and `app_return_denied`; and
- `shell_context_revoked` when membership, principal, environment, or
  application availability invalidates an active shell context.

A denial aimed at an unauthorized tenant must not create a record inside that
tenant. Record it under the currently authorized source tenant when applicable,
or in the separately controlled environment security-audit boundary with the
requested target redacted or irreversibly referenced. Audit search and
dashboards remain tenant-scoped unless a separately approved platform-security
view authorizes broader access.

## Failure behavior

| Condition                                                                                       | Required result                                                                                                                |
| ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Missing or ambiguous tenant context                                                             | Show tenant selection with no domain summaries or application launch. Do not choose the most recent tenant.                    |
| Unauthorized, suspended, or revoked membership                                                  | Deny the switch or launch, clear affected tenant state, and record a redacted denial.                                          |
| Application disabled or capability missing                                                      | Omit it from the effective registry and deny direct launch with a non-enumerating error.                                       |
| Registry unavailable or unverifiable                                                            | Fail closed to a shell error state; do not use an expired registry to open a domain application.                               |
| Handoff signature, issuer, audience, version, state, nonce, time, route, or environment invalid | Deny launch, consume nothing except an approved invalid-attempt record, and expose no target data.                             |
| Handoff replay                                                                                  | Deny even if the principal and membership remain valid.                                                                        |
| Tenant changes during an in-flight request                                                      | Discard the response unless it is bound to the current context; never render it under the new ranch.                           |
| Membership or principal revoked while a domain app is open                                      | The next request fails closed, tenant data is concealed, and Home requires fresh context resolution.                           |
| Invalid or missing return envelope                                                              | Preserve the domain's committed result, show a sanitized navigation failure, and return safely to Home without replaying work. |
| Domain summary unavailable                                                                      | Show an explicit unavailable or stale state without substituting another tenant's cached value.                                |
| Unknown resource reference                                                                      | Return not found without revealing whether the resource exists in another tenant.                                              |

## Acceptance tests

DEV acceptance requires adversarial two-tenant tests at the shell, domain API,
cache, deep-link, and database boundaries.

### Registry and visibility

1. A Tenant A user cannot see Tenant B application enablements, tiles, badges,
   summaries, settings, or hidden-application existence.
2. Viewer, manager, owner, Health privacy, and Finance privacy capabilities
   produce the exact authorized registry; changing only a client-side role or
   tile definition grants nothing.
3. A direct route to a hidden or disabled application is denied by both the
   shell and target domain API.
4. An intentionally unfiltered tenant-enablement repository query remains
   blocked by PostgreSQL RLS.

### Ranch switching

1. A user with two memberships must explicitly select the active ranch; no
   recent-tenant fallback is permitted.
2. Switching from Tenant A to Tenant B cancels A requests, resets navigation,
   and prevents A summaries, recent items, notifications, drafts, and cached
   screens from appearing under B.
3. A request to switch to a tenant without an active membership is denied and
   does not reveal that tenant's name, enabled applications, or records.
4. Revocation between registry display and switch confirmation denies the
   switch using a fresh membership check.

### Handoff and return

1. Tenant A cannot open a Tenant B Property asset, Livestock animal, Finance
   record, or Health route by changing `tenant_id`, `resource_ref`, route,
   audience, environment, or return target.
2. Unsigned, expired, future-dated, replayed, wrong-key, wrong-issuer,
   wrong-audience, wrong-environment, unknown-version, and unknown-route
   handoffs fail closed.
3. A valid handoff whose membership is revoked before acceptance is denied.
4. A valid return cannot switch tenants, grant a capability, inject a route,
   expose domain payloads, or cause a mutation to run again.
5. Restored windows, universal links, notifications, widgets, and shortcuts
   cannot bypass the same handoff and authorization checks.

### Unified Apple application

1. Each supported platform installs one user-visible RanchOS product. Home,
   Property Manager, Livestock Management, and Ranch Finance routes appear
   within that product rather than requiring a second RanchOS-domain launcher.
2. A registry entry can select only a compiled module declared for the running
   platform. A module absent from the build or unsupported on that platform is
   indistinguishable from an unavailable application to the client.
3. Switching from Property Manager to Livestock Management, returning Home,
   switching ranches, restoring a scene, and backgrounding then foregrounding
   RanchOS never exposes the previous module's tenant-bound screen, draft, or
   cached summary under a different module or tenant.
4. iPhone and iPad exercise the same module routes with adaptive navigation;
   Mac verifies independent window contexts; tvOS verifies focus movement,
   readable unavailable states, and the absence of unsupported mutation routes.
5. No feature module can discover, instantiate, or navigate to another module
   through a raw route string, custom URL, `WebView`, or unrestricted payload.

### Domain ownership and data planes

1. Home obtains Property, Livestock, Finance, and Health summaries only through
   each domain's approved read contract; direct database, filesystem, cache,
   index, or unrestricted search access is absent.
2. Property assets remain writable only through Property; animal care remains
   writable only through Livestock; ledger activity remains writable only
   through Finance; veterinary data never enters Ranch Health.
3. Summary caches, deep-link pending state, notifications, audit events, and
   telemetry carry and enforce tenant and environment context.
4. No-result, unavailable, unauthorized, and unknown-resource outcomes remain
   distinguishable to the client without leaking cross-tenant existence.

## Implementation gates

No shell implementation, Apple app target work, static-shell code, fixture
code, compilation, or simulator or device work begins until these design
choices are explicitly approved:

1. the platform owner and versioning process for `RanchOSAppRegistryV1`;
2. the concrete capability names for application visibility, launch, summary
   reads, tenant switching, and shell settings;
3. the signing authority, key custody, algorithm profile, validity window,
   nonce store, and rotation/recovery policy for DEV handoff and return
   envelopes;
4. the allowlisted route and return-target registries for each application;
5. the Health and personal-Finance privacy rules required before their tiles or
   summaries become visible; and
6. tenant-partitioned cache, offline retention, and multiwindow invalidation
   behavior for each supported client; and
7. the RanchOS module-host API, compiled-module inventory, platform support
   matrix, and per-module migration plan from each standalone application.

After those gates and a separate target decision, the smallest possible future
DEV implementation would be a read-only Home containing an explicit tenant
selector and Property application tile for two test tenants. It would use the
shared `TenantContext`, a server-evaluated registry, one compiled read-only
Property module route, redacted audit events, and adversarial cross-tenant
tests. External Property entry and return routes would remain disabled unless
the signed handoff contract is separately approved. Livestock, Finance,
Health, tvOS, live integrations, any existing multi-module hub, summaries,
offline mode, notifications, widgets, and mutations remain outside that future
slice until their respective contracts and tests are approved. This document
does not authorize starting that slice.

## Non-goals

This design does not define or authorize:

- a new authentication provider, session format, bootstrap identity, or
  membership source;
- application database tables, schema migrations, RLS implementation, signing
  keys, DNS, certificates, services, deployment, or Production configuration;
- cross-tenant sharing, transfers, global operator search, or support
  impersonation;
- a unified cross-domain mutation API, ledger, health record, animal record,
  asset record, or search index; or
- a runtime plugin system, remotely downloaded feature code, arbitrary web
  content, or an all-purpose browser inside RanchOS; or
- Production activation or migration of an existing Ranch OS application.

## Related architecture

- [Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md)
- [RanchOS DEV read-only Home and Property module plan](RANCH_OS_DEV_HOME_PROPERTY_MODULE_PLAN.md)
- [Livestock Management design](LIVESTOCK_MANAGEMENT_DESIGN.md)
- [Livestock Management application blueprint](LIVESTOCK_MANAGEMENT_APPLICATION_BLUEPRINT.md)
- [RanchBrain architecture](ARCHITECTURE.md)
- [RanchBrain roadmap](ROADMAP.md)
- [PropertyManager foundational requirements](../../docs/foundation/PROPERTY_MANAGER_FOUNDATIONAL_REQUIREMENTS.md)
- [PropertyManager asset architecture](../../docs/architecture/PROPERTY_MANAGER_ASSET_ARCHITECTURE.md)
