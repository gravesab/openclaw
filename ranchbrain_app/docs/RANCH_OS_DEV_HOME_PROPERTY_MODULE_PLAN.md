# RanchOS DEV read-only Home and Property module plan

Status: DEV planning only; no Apple app, static-shell code, fixture, target,
compilation, simulator, device, deployment, or Production authorization
Scope: Plan the smallest tenant-safe RanchOS hub slice in DEV

This plan is a design-review artifact. It records the intended smallest future
DEV Home slice. It does not authorize Apple app targets, static-shell code,
local fixtures, target restructuring, compilation, simulator or device work,
signing, authentication, identity, tenant membership, database schema, domain
API, deployment, migration, or Production.

After the Home-shell design gates and a separate target decision are explicitly
approved, the smallest possible future implementation would be a Home root plus
one Property Manager tile. Livestock, Finance, Health, tvOS, live integrations,
and any existing multi-module hub remain outside that future slice.

## Outcome

The planned first increment, only after those separate approvals, would give
an already-authorized DEV user a Home root with an explicit active ranch and
one Property Manager tile. Selecting the tile would enter a compiled Property
module inside RanchOS, where a bounded Property read route can be shown only
after its normal domain authorization. Returning Home would clear only module
navigation state; it would not alter Property data.

No separate PropertyManager icon would be removed or redirected in that
increment. The existing PropertyManager app would remain the source of truth
and continue to run independently while its read-only module boundary is
proven.

## Preconditions

No implementation, Apple app target change, fixture code, compilation, or
simulator or device work can start until the following existing contracts are
named and reviewed without modifying them:

1. A DEV `VerifiedPrincipal` and `TenantContext` resolution path that already
   distinguishes one authorized test tenant from another.
2. A server-evaluated effective registry response for a Property entry, or a
   deliberately constrained test seam that returns the same typed contract for
   exactly two test tenants.
3. A read-only Property domain route and response model with tenant context,
   provenance, freshness, unavailable state, and no mutation capability.
4. Exact capability names for Home visibility, Property visibility, Property
   launch, and the selected Property read route.
5. The shared RanchOS app project has a named iOS/iPadOS, macOS, and tvOS
   target location. Naming that location is a planning precondition. This plan
   does not authorize changing those targets, compiling them, or running them.

If any precondition is absent, stop at its contract definition. Do not emulate
it with an unauthenticated client fixture, a client-selected tenant, or a
cross-domain data query.

## Planned seams

The future RanchOS target contains these narrow source-level seams. Names are
planning names, not a public SDK.

| Seam                  | Responsibility                                                                                      | Must not do                                                     |
| --------------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `RanchOSHomeStore`    | Holds the current resolved presentation context, effective registry, and Home loading state.        | Persist a mutable global tenant or calculate authorization.     |
| `RanchOSModuleHost`   | Selects a compiled module from an effective registry entry and resets module state on context loss. | Load arbitrary code, URLs, or other module internals.           |
| `PropertyModule`      | Owns Property routes, views, loading state, and its domain client.                                  | Read another domain's data or accept an untyped route payload.  |
| `PropertyRoute`       | Defines the closed, read-only route set for this increment.                                         | Carry arbitrary paths, IDs with authority, or mutation intents. |
| `RanchOSRouteContext` | Carries immutable environment, active tenant reference, surface, app ID, and correlation ID.        | Act as proof of current authorization without revalidation.     |

`RanchOSModuleHost` receives an already-authorized `app_id` and can construct
only the corresponding compiled module. `PropertyModule` revalidates the route
and binds every request to the current context. A change in principal,
membership, active ranch, application availability, or environment invalidates
the module route and returns to Home.

## Delivery sequence

This sequence is future work. This plan does not authorize starting it.

### 1. Freeze the interfaces

Write source-independent Swift protocol and value-type sketches for the five
seams, including explicit loading, unavailable, denied, and stale states. Keep
the sketches in a design review artifact until a separate target decision is
approved. Do not add them to an existing PropertyManager or tvOS target.

### 2. Define the smallest registry fixture

Specify two test tenants and a server-shaped effective registry response:
Property is visible and launchable for one authorized capability combination,
and absent for the other. The fixture is a contract test input only; it is not
a substitute for the eventual registry service or tenant enforcement.

### 3. Define the Property read route

Choose one safe, read-only presentation route, such as an authorized asset
list summary. Document its domain-owned request, response, loading,
unavailable, and denied semantics. It must not include create, edit, complete,
photo upload, meter entry, or work-request mutation behavior.

### 4. Add host and module tests before UI work

Test module selection, hidden Property behavior, tenant switching, context
revocation, unavailable registry, denied Property route, and return-to-Home
state clearing. Use typed fixtures and fake domain clients; do not use a real
credential, live DEV service, or a hand-created tenant context as proof.

### 5. Build the adaptive Home proof

After a separate target decision, a later approval could implement only the
Home root and one Property tile. The iPhone form would use an adaptive
navigation stack; iPad and macOS can use a sidebar. tvOS, Livestock, Finance,
Health, live integrations, and any existing multi-module hub remain outside
that future first Property increment unless separately approved. All forms
would present the same effective registry outcome.

### 6. Add the read-only Property module proof

Host the chosen Property route in the compiled module, bind it to the route
context, and show explicit loading, unavailable, and denied states. No shell
screen reads a Property repository or API client directly.

### 7. Verify the real boundary separately

Only after source tests pass, run an authenticated DEV proof against the
existing Property domain service with an approved test user and test tenants.
Record only non-secret outcomes. This is a later operational gate, not a
substitute for source or tenant-isolation tests.

## Acceptance evidence

A future implementation would be ready for the next module only when all of
the following are true:

1. Home shows exactly the server-authorized registry for each of two tenants.
2. An unavailable or hidden Property tile cannot be opened through UI state,
   restoration, a direct route, or stale module state.
3. Switching ranches cancels Property loads, clears Property navigation, and
   returns to Home before the new registry is presented.
4. Property results carry the active context and never appear after it changes.
5. Property read requests remain read-only and the shell has no Property data
   access of its own.
6. The resulting target still has one RanchOS app icon for its platform, while
   legacy PropertyManager packaging remains unchanged until its separate
   migration approval.

## Deferred decisions

- App groups, signing, entitlements, and App Store or TestFlight migration.
- Authentication/session changes, membership enrollment, registry service,
  signing keys, handoff issuance, and external deep-link activation.
- Finance, Livestock, Health, tvOS, live integrations, the existing
  multi-module hub, summaries, mutations, offline mode, notifications,
  widgets, Top Shelf, and multiwindow implementation.
- Deletion, redirection, or migration of standalone applications and their
  local data.
