"""Membership sources feeding TenantContextResolver (P3).

The resolver is storage-agnostic; these stores adapt membership facts into
the (users, tenants, memberships) snapshot it consumes. Fail closed: any
store failure surfaces as MembershipStoreError, which the server maps to
503 — never to an allow, never to a 500 traceback.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from ..tenancy import (
    Capability,
    Role,
    TenancyError,
    TenancyErrorCode,
    Tenant,
    TenantContext,
    TenantContextResolver,
    TenantMembership,
    User,
    VerifiedPrincipal,
)

ROLE_BY_NAME = {role.value: role for role in Role}


class MembershipStoreError(Exception):
    """Membership facts could not be loaded (store down, malformed data)."""


class MembershipStore(Protocol):
    def snapshot(self) -> tuple[list[User], list[Tenant], list[TenantMembership]]:
        """Current membership facts. Raises MembershipStoreError on failure."""
        ...


@dataclass(frozen=True)
class StaticMembershipStore:
    """Fixed in-memory facts. Tests + DEV bootstrap via JSON file."""

    users: tuple[User, ...] = ()
    tenants: tuple[Tenant, ...] = ()
    memberships: tuple[TenantMembership, ...] = ()

    def snapshot(self):
        return list(self.users), list(self.tenants), list(self.memberships)

    @classmethod
    def from_json_file(cls, path: str | Path) -> "StaticMembershipStore":
        try:
            data = json.loads(Path(path).read_text())
        except Exception as error:
            raise MembershipStoreError(f"cannot read membership file: {error}") from error
        try:
            users = [
                User(id=str(u["id"]), principal_id=str(u["principal_id"]),
                     status=str(u.get("status", "active")))
                for u in data.get("users", [])
            ]
            tenants = [
                Tenant(id=str(t["id"]), slug=str(t.get("slug", t["id"])),
                       display_name=str(t.get("display_name", t["id"])),
                       status=str(t.get("status", "active")))
                for t in data.get("tenants", [])
            ]
            memberships = [
                TenantMembership(tenant_id=str(m["tenant_id"]), user_id=str(m["user_id"]),
                                 role=_role(str(m["role"])),
                                 status=str(m.get("status", "active")))
                for m in data.get("memberships", [])
            ]
        except (KeyError, TypeError, ValueError) as error:
            raise MembershipStoreError(f"malformed membership file: {error}") from error
        return cls(users=tuple(users), tenants=tuple(tenants), memberships=tuple(memberships))


def _role(name: str) -> Role:
    try:
        return ROLE_BY_NAME[name]
    except KeyError:
        raise MembershipStoreError(f"unknown role {name!r}") from None


class PostgresMembershipStore:
    """Authorizes one OIDC caller through ``ranchos.resolve_api_membership``.

    Migration 007 links ``(issuer, subject)`` to ``users.id``. The request
    path calls that SECURITY DEFINER function for a single row and then
    ``TenantContextResolver``. ``snapshot`` remains for tests and DEV
    bootstrap only; it is not the API request path.

    `connect` is an injected zero-arg DBAPI connector (psycopg-style); the
    driver import lives with the caller so this module stays stdlib-only.
    """

    def __init__(self, connect) -> None:
        self._connect = connect

    def snapshot(self):
        try:
            conn = self._connect()
        except Exception as error:
            raise MembershipStoreError(f"membership database unreachable: {error}") from error
        try:
            users = [
                User(id=str(r[0]), principal_id=str(r[1]), status=str(r[2]))
                for r in self._rows(conn, "SELECT id, principal_id, status FROM ranchos.users")
            ]
            tenants = [
                Tenant(id=str(r[0]), slug=str(r[1]), display_name=str(r[2]), status=str(r[3]))
                for r in self._rows(
                    conn, "SELECT id, slug, display_name, status FROM ranchos.tenants")
            ]
            memberships = [
                TenantMembership(tenant_id=str(r[0]), user_id=str(r[1]),
                                 role=_role(str(r[2])), status=str(r[3]))
                for r in self._rows(
                    conn,
                    "SELECT tenant_id, user_id, role, status FROM ranchos.tenant_memberships")
            ]
        except MembershipStoreError:
            raise
        except Exception as error:
            raise MembershipStoreError(f"membership query failed: {error}") from error
        finally:
            try:
                conn.close()
            except Exception:
                pass
        return users, tenants, memberships

    def resolve_principal(
        self,
        *,
        issuer: str,
        subject: str,
        tenant_id: str,
        principal: VerifiedPrincipal,
        capability: Capability,
    ) -> TenantContext:
        """One-row membership lookup. Denials share one tenancy error."""

        try:
            conn = self._connect()
        except Exception as error:
            raise MembershipStoreError(f"membership database unreachable: {error}") from error
        try:
            cursor = conn.cursor()
            try:
                cursor.execute(
                    "SELECT user_id, role, user_status, tenant_status, membership_status "
                    "FROM ranchos.resolve_api_membership(%s, %s, %s)",
                    (issuer, subject, tenant_id),
                )
                row = cursor.fetchone()
            finally:
                try:
                    cursor.close()
                except Exception:
                    pass
        except TenancyError:
            raise
        except Exception as error:
            sqlstate = getattr(error, "pgcode", None)
            if sqlstate in {"42501", "22P02"}:
                raise TenancyError(
                    "tenant context is not authorized",
                    TenancyErrorCode.TENANT_NOT_AUTHORIZED,
                ) from error
            raise MembershipStoreError(f"membership query failed: {error}") from error
        finally:
            try:
                conn.close()
            except Exception:
                pass
        if row is None:
            raise TenancyError(
                "tenant context is not authorized",
                TenancyErrorCode.TENANT_NOT_AUTHORIZED,
            )
        user_id, role, user_status, tenant_status, membership_status = row
        resolver = TenantContextResolver(
            environment=principal.environment,
            users=[User(id=str(user_id), principal_id=principal.id, status=str(user_status))],
            tenants=[Tenant(
                id=str(tenant_id), slug=str(tenant_id), display_name=str(tenant_id),
                status=str(tenant_status),
            )],
            memberships=[TenantMembership(
                tenant_id=str(tenant_id), user_id=str(user_id),
                role=_role(str(role)), status=str(membership_status),
            )],
        )
        return resolver.resolve(
            principal=principal,
            requested_tenant_id=str(tenant_id),
            capability=capability,
        )

    @staticmethod
    def _rows(conn, sql):
        cursor = conn.cursor()
        try:
            cursor.execute(sql)
            return list(cursor.fetchall())
        finally:
            try:
                cursor.close()
            except Exception:
                pass
