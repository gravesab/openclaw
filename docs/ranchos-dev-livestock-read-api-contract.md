# RanchOS DEV Livestock Read API contract

Status: contract only. No service, deployment, migration, credential, or Apple change is authorized.
Scope: RanchOS Hub live Livestock reads in DEV.
Contract module: `ranchbrain_app/ranchbrain/livestock_read_api.py`

RanchOS Hub may read Livestock only through this versioned contract. Apple clients do not open a database connection. The current Hub boundary stays `RanchOSLivestockAuthorizedReadProvider.readDashboard()`. This contract does not add a provider, URL, or credential to the Apple project.

## Authorization

Every read requires all of the following. A miss fails closed and returns no livestock facts.

1. A `VerifiedPrincipal` produced by the OpenClaw-authoritative adapter.
2. An explicit tenant selection. There is no default tenant.
3. One active user, one active tenant, and one active membership in that tenant.
4. Capability `livestock.read`, resolved by `TenantContextResolver`.

The tenant identifier on a request is a routing hint. Query keys `tenant_id`, `tenant`, `origin`, `fixture`, `fact_freshness`, and `classification` are rejected. Callers cannot supply role, capability, or a second tenant filter.

## Read routes

Version: `v1`
Prefix: `/api/ranchos/livestock/v1`
Allowed method: `GET`
Mutation routes: none
Write verbs `POST`, `PUT`, `PATCH`, and `DELETE`: not defined

| Operation                     | Path                                                           | Hub boundary                                             |
| ----------------------------- | -------------------------------------------------------------- | -------------------------------------------------------- |
| Herd summary                  | `GET /api/ranchos/livestock/v1/herd`                           | `RanchOSLivestockAuthorizedReadProvider.readDashboard()` |
| Animal list                   | `GET /api/ranchos/livestock/v1/animals`                        | Not a method on the current provider                     |
| Animal detail                 | `GET /api/ranchos/livestock/v1/animals/{animal_id}`            | Not a method on the current provider                     |
| Provenance and fact freshness | `GET /api/ranchos/livestock/v1/animals/{animal_id}/provenance` | Not a method on the current provider                     |

Animal list, detail, and provenance are reserved for a later provider expansion. They are not added to the Apple project by this contract.

### Herd summary

The herd response carries `ranch_name`, `herd_count`, and three summary cards: `herd-count`, `fact-freshness`, and `records-review`. Card status values are the existing Hub raw values `Care due`, `Current`, and `Review`.

`readDashboard()` consumes the camelCase projection:

- `ranchName`
- `herdCount`
- `summaries[]` with `id`, `title`, `detail`, `status`

A successful herd read is origin `live` and session `live`. It is not the Hub development fixture.

Fact freshness on the card is derived only from server-supplied animal facts:

- `incomplete` or `conflicting` maps to `Review`
- otherwise `stale` maps to `Care due`
- otherwise the card is `Current`

Stale facts are the only live signal that maps to `Care due`. The contract does not invent care schedules.

### Animal list and detail

Each animal fact contains `animal_id`, `display_name`, `species_code`, `production_type_code`, `breed_code`, `lifecycle_status` (`active`), `fact_freshness` (`current`, `stale`, `incomplete`, or `conflicting`), an optional active identifier (`ear_tag`, `rfid`, `brand`, or `registry_number`), and provenance.

Species, production type, and breed stay inside the existing Livestock read catalog. Live lifecycle status is `active`, matching the current persistence check. Archived sample animals remain fixture-only.

### Provenance and fact freshness

Provenance uses the existing fact fields `source_type`, `source_id`, `source_version`, and `observed_at`, plus contract origin `live`. `observed_at` is timezone-aware. The provenance route returns those fields with `fact_freshness` for one animal in the authorized tenant.

## Prohibitions

- Apple clients use this authorized read API only. They do not connect to the database.
- Unauthenticated reads are rejected before any fact is loaded.
- A principal for tenant A cannot select tenant B. A fact whose `tenant_id` is not the authorized tenant fails the read closed. Missing and foreign animal ids use the same not-available result and do not echo the other tenant's facts.
- No mutation route and no write verb is defined.

Live facts cannot be labeled fixture data. Fixture or synthetic sources (`synthetic_dev_fixture`, `fixture`, `development_fixture`, `sample_catalog`, or a `sample-catalog` version) cannot be returned as live.

## DEV implementation plan

These gates are sequential and not started. This contract does not authorize any of them. Production, credentials, signing, migrations, and the Apple project stay unchanged until a later explicit change.

1. **Service implementation.** Implement this route table and `authorize_livestock_read` behind a DEV-only GET adapter. Add no routes and no write verbs.
2. **Disposable tenant-isolation proof.** Prove on an isolated disposable DEV database that tenant A cannot read tenant B. Do not apply migrations to Production. These contract tests do not replace that proof.
3. **DEV deployment.** Deploy the read service to DEV only after gates 1 and 2 pass. Do not change Production configuration, credentials, or signing.
4. **Authenticated RanchOS integration.** Implement `RanchOSLivestockAuthorizedReadProvider.readDashboard()` against the herd projection. Keep URL and credentials out of `RanchOSLivestockConnection`.
5. **Physical-device acceptance.** On a physical device, confirm a resolved provider read presents `RanchOSLivestockSession.live` and does not present the development fixture. Sample-animal browsing stays ineligible for live presentation.
