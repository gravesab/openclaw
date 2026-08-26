# RanchBrain Data Model

## Memory Record

Fields:

- id
- created_at
- updated_at
- module
- category
- title
- body
- tags
- source_type
- source_path
- confidence
- privacy_level

## Modules

- system
- budget
- health
- property
- livestock
- projects
- homeassistant

## Tenancy

The current alpha data model is local and single-tenant. The approved Ranch OS
tenancy model introduces Tenant, User, TenantMembership, non-null tenant-owned
`tenant_id`, tenant-aware relationships, and audit attribution. See
[Ranch OS multi-tenancy design](MULTI_TENANCY_DESIGN.md) before adding or
migrating records.

Livestock records use stable animal identities, tenant-scoped identifiers,
lifecycle history, and herd assignments. See [Livestock Management design](LIVESTOCK_MANAGEMENT_DESIGN.md)
before adding or migrating livestock data.
