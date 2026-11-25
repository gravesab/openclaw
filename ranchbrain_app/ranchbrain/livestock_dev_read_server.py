"""Loopback-only Livestock DEV read server for a local app test.

GET /api/ranchos/livestock/v1/animals serves the Livestock DEV app.
GET /api/ranchos/livestock/v1/herd prepares the RanchOS TV/iPhone summary
from DEV Postgres. Apple clients do not open the database. The process binds
127.0.0.1, writes a mode-0600 ticket outside the repo, and does not print
the token.
"""

from __future__ import annotations

import hmac
import json
import os
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from secrets import token_urlsafe

from ranchbrain.livestock_dev_postgres import LivestockPostgresError, LivestockPostgresRecords, envelope, occurred_at_stamp
from ranchbrain.livestock_read_api import (
    API_PREFIX,
    DataOrigin,
    FactFreshness,
    LivestockAnimalReadFactV1,
    LivestockAuthorizedReadContract,
    LivestockProvenanceV1,
    LivestockReadResponseV1,
    LiveLifecycleStatus,
    herd_summary_payload,
)
from ranchbrain.tenancy import (
    Role,
    Tenant,
    TenantContextResolver,
    TenantMembership,
    User,
    VerifiedPrincipal,
)

LOOPBACK_HOST = "127.0.0.1"
# A two-hour ticket expired during the work day and the app opened the sample session.
DEV_SESSION_HOURS = 18
# One address so a restart does not force a new ticket or a new iPhone copy.
DEV_LOOPBACK_PORT = 18761
ANIMALS_PATH = f"{API_PREFIX}/animals"
HERD_PATH = f"{API_PREFIX}/herd"
TENANT_ID = "tenant-a"
TENANT_NAME = "North Ranch"
PRINCIPAL_ID = "dev-read-principal"
USER_ID = "dev-read-user"
TICKET_NAME = "dev-read.json"
DEV_ANIMALS = (
    ("11111111-2222-4333-8444-555555555551", "Aster", "cattle", "beef", "angus", "AST-1"),
    ("11111111-2222-4333-8444-555555555552", "Briar", "goat", "dairy", "boer", "BR-2"),
)


class LivestockDevReadServerError(RuntimeError):
    pass


def default_ticket_path() -> Path:
    return Path.home() / "Library" / "Application Support" / "RanchOSLivestock" / TICKET_NAME


def require_loopback(host: str) -> str:
    if host != LOOPBACK_HOST:
        raise LivestockDevReadServerError("livestock DEV read binds 127.0.0.1 only")
    return host


def _live_animal(animal_id: str, name: str, species: str, production: str, breed: str, tag: str, observed: datetime) -> LivestockAnimalReadFactV1:
    return LivestockAnimalReadFactV1(
        animal_id,
        TENANT_ID,
        name,
        species,
        production,
        breed,
        LiveLifecycleStatus.ACTIVE,
        FactFreshness.CURRENT,
        "ear_tag",
        tag,
        LivestockProvenanceV1("ranch_record", animal_id, "read-model-v1", observed, DataOrigin.LIVE),
    )


class _DevSource:
    def __init__(self, observed: datetime):
        self.animals = tuple(_live_animal(*row, observed) for row in DEV_ANIMALS)

    def tenant_display_name(self, tenant_id: str) -> str | None:
        return TENANT_NAME if tenant_id == TENANT_ID else None

    def animals_for_tenant(self, tenant_id: str) -> tuple[LivestockAnimalReadFactV1, ...]:
        if tenant_id != TENANT_ID:
            return ()
        return self.animals


def dev_contract(now: datetime, valid_until: datetime | None = None) -> _FixedPrincipalContract:
    observed = now - timedelta(hours=1)
    principal = VerifiedPrincipal(
        id=PRINCIPAL_ID,
        principal_type="human",
        environment="development",
        lifecycle_state="active",
        assurance_profile="dev-loopback",
        session_reference="dev-read-session",
        valid_from=now - timedelta(minutes=5),
        valid_until=valid_until or now + timedelta(hours=DEV_SESSION_HOURS),
        correlation_id="dev-read",
    )
    resolver = TenantContextResolver(
        environment="development",
        users=(User(id=USER_ID, principal_id=PRINCIPAL_ID),),
        tenants=(Tenant(id=TENANT_ID, slug="north", display_name=TENANT_NAME),),
        memberships=(TenantMembership(tenant_id=TENANT_ID, user_id=USER_ID, role=Role.VIEWER),),
    )
    return _FixedPrincipalContract(resolver, _DevSource(observed), principal, now)


class _FixedPrincipalContract:
    """The loopback process is the only caller. The token is not a tenant claim."""

    def __init__(self, resolver, source, principal: VerifiedPrincipal, now: datetime):
        self._contract = LivestockAuthorizedReadContract(resolver, source)
        self._principal = principal
        self._now = now

    def read_animals(self, requested_tenant_id: str) -> LivestockReadResponseV1:
        return self._contract.execute(
            principal=self._principal,
            requested_tenant_id=requested_tenant_id,
            method="GET",
            path=ANIMALS_PATH,
            now=self._now,
        )

    def read_herd(self, requested_tenant_id: str) -> LivestockReadResponseV1:
        return self._contract.execute(
            principal=self._principal,
            requested_tenant_id=requested_tenant_id,
            method="GET",
            path=HERD_PATH,
            now=self._now,
        )


def response_payload(response: LivestockReadResponseV1) -> dict[str, object]:
    return {
        "api_version": response.api_version,
        "operation": response.operation,
        "origin": response.origin.value,
        "body": dict(response.body),
    }


def _parse_ticket_expiry(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        expiry = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    return expiry


def reusable_ticket(path: Path, base_url: str, now: datetime) -> tuple[str, datetime] | None:
    """Keep the current ticket when a restart binds the same loopback address."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    token = payload.get("token")
    if not isinstance(token, str) or not token:
        return None
    if payload.get("baseURL") != base_url or payload.get("tenantID") != TENANT_ID:
        return None
    expiry = _parse_ticket_expiry(payload.get("expiresAt"))
    if expiry is None or expiry <= now:
        return None
    return token, expiry


def write_ticket(path: Path, base_url: str, token: str, expires_at: datetime) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    payload = {
        "baseURL": base_url,
        "token": token,
        "tenantID": TENANT_ID,
        "expiresAt": expires_at.replace(microsecond=0).isoformat(),
    }
    data = json.dumps(payload).encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    descriptor = os.open(path, flags, 0o600)
    try:
        os.write(descriptor, data)
    finally:
        os.close(descriptor)
    os.chmod(path, 0o600)


class LivestockDevReadServer(ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(
        self,
        token: str,
        contract: _FixedPrincipalContract,
        address: tuple[str, int],
        records: LivestockPostgresRecords | None = None,
    ):
        require_loopback(address[0])
        self.token = token
        self.contract = contract
        self.records = records
        super().__init__(address, _Handler)


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802
        self._read()

    def do_POST(self) -> None:  # noqa: N802
        server: LivestockDevReadServer = self.server  # type: ignore[assignment]
        if server.records is None:
            self._reject_write()
            return
        self._write()

    def do_PUT(self) -> None:  # noqa: N802
        self._reject_write()

    def do_PATCH(self) -> None:  # noqa: N802
        self._reject_write()

    def do_DELETE(self) -> None:  # noqa: N802
        self._reject_write()

    def log_message(self, format: str, *args) -> None:
        return

    def _reject_write(self) -> None:
        self._send(405, {"error": "livestock DEV read allows GET only"}, allow="GET")

    def _read(self) -> None:
        path = self.path.split("?", 1)[0]
        if path not in (ANIMALS_PATH, HERD_PATH):
            self._send(404, {"error": "not found"})
            return
        server = self._authorized()
        if server is None:
            return
        tenant = (self.headers.get("X-RanchOS-Tenant") or "").strip()
        try:
            if path == HERD_PATH:
                if server.records is None:
                    payload = response_payload(server.contract.read_herd(tenant))
                else:
                    payload = herd_summary_payload(server.records.hub_dashboard(TENANT_NAME))
            elif server.records is None:
                payload = response_payload(server.contract.read_animals(tenant))
            else:
                payload = envelope(server.records.animals(), server.records.herds())
        except LivestockPostgresError as error:
            self._send(503, {"error": str(error)})
            return
        except Exception:
            self._send(403, {"error": "livestock read was not authorized"})
            return
        self._send(200, payload)

    def _authorized(self) -> LivestockDevReadServer | None:
        server: LivestockDevReadServer = self.server  # type: ignore[assignment]
        presented = _bearer(self.headers.get("Authorization"))
        if not presented or not hmac.compare_digest(presented, server.token):
            self._send(401, {"error": "unauthorized"})
            return None
        tenant = (self.headers.get("X-RanchOS-Tenant") or "").strip()
        if tenant != TENANT_ID:
            self._send(403, {"error": "tenant selection was not authorized"})
            return None
        return server

    def _write(self) -> None:
        server = self._authorized()
        if server is None or server.records is None:
            return
        parts = [part for part in self.path.split("?", 1)[0].split("/") if part]
        prefix = [part for part in ANIMALS_PATH.split("/") if part]
        if parts == prefix:
            body = self._json_body()
            try:
                animal_id = server.records.create_animal(
                    str(body.get("display_name", "")),
                    str(body.get("species_code", "")),
                    str(body.get("production_type_code", "")),
                    str(body.get("breed_code", "")),
                    str(body.get("pet_breed", "")),
                    str(body.get("pet_mix_one", "")),
                    str(body.get("pet_mix_two", "")),
                    str(body.get("pet_species", "")),
                    str(body.get("pet_species_other", "")),
                )
            except LivestockPostgresError as error:
                self._send(409, {"error": str(error)})
                return
            self._send(200, {"saved": True, "animal_id": animal_id})
            return
        if parts == prefix + ["herds"]:
            body = self._json_body()
            try:
                herd_id = server.records.create_herd(str(body.get("name", "")), str(body.get("notes", "")))
            except LivestockPostgresError as error:
                self._send(409, {"error": str(error)})
                return
            self._send(200, {"saved": True, "herd_id": herd_id})
            return
        if len(parts) == len(prefix) + 3 and parts[len(prefix)] == "herds" and parts[-1] == "retire":
            try:
                server.records.retire_herd(parts[len(prefix) + 1])
            except LivestockPostgresError as error:
                self._send(409, {"error": str(error)})
                return
            self._send(200, {"saved": True})
            return
        if len(parts) == len(prefix) + 3 and parts[len(prefix)] == "herds" and parts[-1] == "name":
            body = self._json_body()
            try:
                server.records.rename_herd(parts[len(prefix) + 1], str(body.get("name", "")))
            except LivestockPostgresError as error:
                self._send(409, {"error": str(error)})
                return
            self._send(200, {"saved": True})
            return
        if parts[len(prefix) : len(prefix) + 1] == ["herds"] and len(parts) in (
            len(prefix) + 4,
            len(prefix) + 6,
        ):
            herd_id = parts[len(prefix) + 1]
            action = parts[len(prefix) + 2]
            body = self._json_body()
            event_id = ""
            try:
                if action == "care" and len(parts) == len(prefix) + 4:
                    occurred_at = str(body.get("occurred_at", "")) or occurred_at_stamp(datetime.now(timezone.utc))
                    event_id = server.records.record_care(
                        event_type=str(body.get("type", "")),
                        occurred_at=occurred_at,
                        confirmed=body.get("confirmed") is True,
                        item_name=str(body.get("item_name", "")),
                        item_kind=str(body.get("item_kind", "")),
                        herd_id=herd_id,
                        dosage=str(body.get("dosage", "")),
                    )
                elif action == "care" and len(parts) == len(prefix) + 6 and parts[-1] == "correct":
                    event_id = server.records.correct_care(
                        "",
                        parts[-2],
                        str(body.get("occurred_at", "")),
                        str(body.get("reason", "")),
                        body.get("confirmed") is True,
                        str(body.get("item_name", "")),
                        str(body.get("item_kind", "")),
                        str(body.get("cost_id", "")),
                        str(body.get("cost_amount", "")),
                        herd_id,
                        dosage=str(body.get("dosage", "")),
                    )
                elif action == "consumption" and len(parts) == len(prefix) + 4:
                    observed_at = str(body.get("observed_at", "")) or occurred_at_stamp(datetime.now(timezone.utc))
                    event_id = server.records.record_consumption(
                        input_type=str(body.get("input_type", "")),
                        quantity=str(body.get("quantity", "")),
                        unit=str(body.get("unit", "")),
                        observed_at=observed_at,
                        supplier=str(body.get("supplier", "")),
                        batch=str(body.get("batch", "")),
                        frequency=str(body.get("frequency", "")),
                        herd_id=herd_id,
                    )
                elif action == "consumption" and len(parts) == len(prefix) + 6 and parts[-1] == "correct":
                    event_id = server.records.correct_consumption(
                        "",
                        parts[-2],
                        str(body.get("quantity", "")),
                        str(body.get("unit", "")),
                        str(body.get("frequency", "")),
                        str(body.get("observed_at", "")),
                        str(body.get("supplier", "")),
                        str(body.get("batch", "")),
                        str(body.get("reason", "")),
                        body.get("confirmed") is True,
                        str(body.get("cost_id", "")),
                        str(body.get("cost_amount", "")),
                        herd_id,
                    )
                elif action == "costs" and len(parts) == len(prefix) + 4:
                    server.records.record_cost(
                        amount=str(body.get("amount", "")),
                        finance_reference=str(body.get("finance_reference", "")),
                        confirmed=body.get("confirmed") is True,
                        frequency=str(body.get("frequency", "")),
                        feed_type=str(body.get("feed_type", "")),
                        care_event_id=str(body.get("care_event_id", "")),
                        consumption_id=str(body.get("consumption_id", "")),
                        herd_id=herd_id,
                    )
                elif action == "costs" and len(parts) == len(prefix) + 6 and parts[-1] == "correct":
                    event_id = server.records.correct_cost(
                        "",
                        parts[-2],
                        str(body.get("amount", "")),
                        str(body.get("reason", "")),
                        body.get("confirmed") is True,
                        herd_id,
                    )
                else:
                    self._send(404, {"error": "not found"})
                    return
            except LivestockPostgresError as error:
                self._send(409, {"error": str(error)})
                return
            payload: dict[str, object] = {"saved": True}
            if event_id:
                payload["event_id"] = event_id
            self._send(200, payload)
            return
        if parts[: len(prefix)] != prefix or len(parts) not in (len(prefix) + 2, len(prefix) + 4):
            self._send(404, {"error": "not found"})
            return
        body = self._json_body()
        animal_id = parts[len(prefix)]
        action = parts[len(prefix) + 1]
        event_id = ""
        try:
            if action == "retire" and len(parts) == len(prefix) + 2:
                server.records.retire_animal(
                    animal_id,
                    str(body.get("reason", "")),
                    str(body.get("sale_amount", "")),
                    str(body.get("sale_on", "")),
                )
            elif action == "identifiers" and len(parts) == len(prefix) + 2:
                server.records.assign_identifier(animal_id, str(body.get("kind", "")), str(body.get("value", "")))
            elif action == "identifiers" and len(parts) == len(prefix) + 4 and parts[-1] == "retire":
                server.records.retire_identifier(animal_id, parts[-2], str(body.get("reason", "")))
            elif action == "herd" and len(parts) == len(prefix) + 2:
                server.records.assign_herd(animal_id, str(body.get("herd_id", "")))
            elif action == "name" and len(parts) == len(prefix) + 2:
                server.records.rename_animal(animal_id, str(body.get("display_name", "")))
            elif action == "classification" and len(parts) == len(prefix) + 2:
                server.records.update_classification(
                    animal_id,
                    str(body.get("production_type_code", "")),
                    str(body.get("breed_code", "")),
                )
            elif action == "breeding" and len(parts) == len(prefix) + 2:
                server.records.update_breeding(
                    animal_id,
                    str(body.get("sire_animal_id", "")),
                    str(body.get("dam_animal_id", "")),
                    str(body.get("bred_with_animal_id", "")),
                )
            elif action == "lifecycle" and len(parts) == len(prefix) + 2:
                occurred_at = str(body.get("occurred_at", "")) or occurred_at_stamp(datetime.now(timezone.utc))
                event_id = server.records.record_lifecycle(
                    animal_id,
                    str(body.get("type", "")),
                    occurred_at,
                    str(body.get("weight_pounds", "")),
                )
            elif action == "lifecycle" and len(parts) == len(prefix) + 4 and parts[-1] == "correct":
                server.records.correct_lifecycle(
                    animal_id,
                    parts[-2],
                    str(body.get("occurred_at", "")),
                    str(body.get("reason", "")),
                    body.get("confirmed") is True,
                    str(body.get("weight_pounds", "")),
                    str(body.get("cost_id", "")),
                    str(body.get("cost_amount", "")),
                )
            elif action == "care" and len(parts) == len(prefix) + 4 and parts[-1] == "correct":
                event_id = server.records.correct_care(
                    animal_id,
                    parts[-2],
                    str(body.get("occurred_at", "")),
                    str(body.get("reason", "")),
                    body.get("confirmed") is True,
                    str(body.get("item_name", "")),
                    str(body.get("item_kind", "")),
                    str(body.get("cost_id", "")),
                    str(body.get("cost_amount", "")),
                    dosage=str(body.get("dosage", "")),
                )
            elif action == "consumption" and len(parts) == len(prefix) + 4 and parts[-1] == "correct":
                event_id = server.records.correct_consumption(
                    animal_id,
                    parts[-2],
                    str(body.get("quantity", "")),
                    str(body.get("unit", "")),
                    str(body.get("frequency", "")),
                    str(body.get("observed_at", "")),
                    str(body.get("supplier", "")),
                    str(body.get("batch", "")),
                    str(body.get("reason", "")),
                    body.get("confirmed") is True,
                    str(body.get("cost_id", "")),
                    str(body.get("cost_amount", "")),
                )
            elif action == "costs" and len(parts) == len(prefix) + 4 and parts[-1] == "correct":
                event_id = server.records.correct_cost(
                    animal_id,
                    parts[-2],
                    str(body.get("amount", "")),
                    str(body.get("reason", "")),
                    body.get("confirmed") is True,
                )
            elif action == "care" and len(parts) == len(prefix) + 2:
                occurred_at = str(body.get("occurred_at", "")) or occurred_at_stamp(datetime.now(timezone.utc))
                event_id = server.records.record_care(
                    animal_id,
                    str(body.get("type", "")),
                    occurred_at,
                    body.get("confirmed") is True,
                    str(body.get("item_name", "")),
                    str(body.get("item_kind", "")),
                    dosage=str(body.get("dosage", "")),
                )
            elif action == "consumption" and len(parts) == len(prefix) + 2:
                observed_at = str(body.get("observed_at", "")) or occurred_at_stamp(datetime.now(timezone.utc))
                event_id = server.records.record_consumption(
                    animal_id,
                    str(body.get("input_type", "")),
                    str(body.get("quantity", "")),
                    str(body.get("unit", "")),
                    observed_at,
                    str(body.get("supplier", "")),
                    str(body.get("batch", "")),
                    str(body.get("frequency", "")),
                )
            elif action == "costs" and len(parts) == len(prefix) + 2:
                server.records.record_cost(
                    animal_id,
                    str(body.get("amount", "")),
                    str(body.get("finance_reference", "")),
                    body.get("confirmed") is True,
                    str(body.get("frequency", "")),
                    str(body.get("feed_type", "")),
                    str(body.get("lifecycle_event_id", "")),
                    str(body.get("care_event_id", "")),
                    str(body.get("consumption_id", "")),
                )
            else:
                self._send(404, {"error": "not found"})
                return
        except LivestockPostgresError as error:
            self._send(409, {"error": str(error)})
            return
        payload: dict[str, object] = {"saved": True}
        if event_id:
            payload["event_id"] = event_id
        self._send(200, payload)

    def _json_body(self) -> dict[str, object]:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        parsed = json.loads(raw.decode("utf-8"))
        return parsed if isinstance(parsed, dict) else {}

    def _send(self, status: int, payload: dict[str, object], allow: str | None = None) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if allow:
            self.send_header("Allow", allow)
        self.end_headers()
        self.wfile.write(body)


def _bearer(header: str | None) -> str:
    if not header:
        return ""
    scheme, _, value = header.partition(" ")
    if scheme.lower() != "bearer":
        return ""
    return value.strip()


def create_server(
    ticket_path: Path,
    port: int = 0,
    now: datetime | None = None,
    records: LivestockPostgresRecords | None = None,
) -> tuple[LivestockDevReadServer, str]:
    moment = now or datetime.now(timezone.utc)
    expected_url = f"http://{LOOPBACK_HOST}:{port}" if port else ""
    reused = reusable_ticket(ticket_path, expected_url, moment) if expected_url else None
    if reused:
        token, expires_at = reused
    else:
        token = token_urlsafe(24)
        expires_at = moment + timedelta(hours=DEV_SESSION_HOURS)
    contract = dev_contract(moment, valid_until=expires_at)
    server = LivestockDevReadServer(token, contract, (LOOPBACK_HOST, port), records)
    bound_port = int(server.server_address[1])
    base_url = f"http://{LOOPBACK_HOST}:{bound_port}"
    if reused is None:
        write_ticket(ticket_path, base_url, token, expires_at)
    return server, base_url


def main() -> None:
    server, base_url = create_server(
        default_ticket_path(), port=DEV_LOOPBACK_PORT, records=LivestockPostgresRecords()
    )
    print(f"Livestock DEV database is ready at {base_url}.")
    print("Tags, lifecycle, care, feed, and cost save to the DEV Postgres database. The ticket stays on this Mac and is not printed.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
