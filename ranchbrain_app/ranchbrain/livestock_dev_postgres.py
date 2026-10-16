"""Livestock rows on the isolated DEV Postgres database.

The Mac process does not keep a database password. Each query runs through
SSH-Dev into the Postgres container's local login.
"""

from __future__ import annotations

import json
import re
import subprocess
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

TENANT_UUID = "11111111-2222-4333-8444-555555555501"
USER_UUID = "11111111-2222-4333-8444-555555555502"
PRINCIPAL_UUID = "11111111-2222-4333-8444-555555555503"
LIVESTOCK_IDENTIFIER_KINDS = frozenset({"ear_tag", "rfid", "brand", "registry_number"})
PET_IDENTIFIER_KINDS = frozenset({"license", "other"})
IDENTIFIER_KINDS = LIVESTOCK_IDENTIFIER_KINDS | PET_IDENTIFIER_KINDS
LIVESTOCK_RETIREMENT_REASONS = frozenset({"deceased", "processed", "sold"})
PET_RETIREMENT_REASONS = frozenset({"rehomed", "deceased", "lost"})
RETIREMENT_REASONS = LIVESTOCK_RETIREMENT_REASONS | PET_RETIREMENT_REASONS
LIFECYCLE_TYPES = frozenset({"intake", "tagged", "weight_recorded"})
CARE_TYPES = frozenset({"observation", "treatment", "surgery", "vaccination", "medication_administration"})
HIGH_IMPACT_CARE = frozenset({"surgery", "vaccination", "medication_administration"})
INPUT_TYPES = frozenset({"feed", "hay", "mineral", "supplement", "dry_food", "wet_food"})
INPUT_UNITS = frozenset({"lb", "kg", "bale", "bag", "scoop"})
FEED_FREQUENCIES = frozenset({"daily", "weekly", "monthly", "quarterly"})
SPECIES_PRODUCTION = {
    "cattle": frozenset({"beef", "dairy", "breeding", "for_sale", "personal_meat"}),
    "dairy_cow": frozenset({"beef", "dairy", "breeding", "for_sale", "personal_meat"}),
    "bison": frozenset({"beef", "breeding", "for_sale", "personal_meat"}),
    "goat": frozenset({"beef", "dairy", "breeding", "for_sale", "personal_meat"}),
    "sheep": frozenset({"breeding", "companion", "for_sale", "personal_meat"}),
    "chicken": frozenset({"layer", "broiler", "breeding", "for_sale", "personal_meat"}),
    "pig": frozenset({"breeding", "companion", "for_sale", "personal_meat"}),
    "horse": frozenset({"breeding", "companion", "for_sale", "personal_meat"}),
    "pet": frozenset({"companion"}),
}
SPECIES_BREEDS = {
    "cattle": frozenset({
        "angus", "ayrshire", "beefmaster", "belted_galloway", "brahman", "brangus", "brown_swiss",
        "charolais", "chianina", "corriente", "devon", "dexter", "dutch_belted", "galloway",
        "gelbvieh", "guernsey", "hereford", "highland", "holstein", "jersey", "limousin",
        "maine_anjou", "milking_shorthorn", "murray_grey", "normande", "piedmontese", "pinzgauer",
        "red_angus", "red_poll", "salers", "santa_gertrudis", "shorthorn", "simmental",
        "south_devon", "tarentaise", "texas_longhorn", "wagyu",
    }),
    "bison": frozenset({"american_bison", "beefalo", "wood_bison"}),
    "goat": frozenset({
        "alpine", "angora", "boer", "kalahari_red", "kiko", "kinder", "lamancha", "myotonic",
        "nigerian_dwarf", "nubian", "oberhasli", "pygmy", "saanen", "savanna", "spanish",
        "toggenburg",
    }),
    "sheep": frozenset({
        "barbados_blackbelly", "bluefaced_leicester", "border_leicester", "cheviot", "clun_forest",
        "columbia", "corriedale", "dorper", "dorset", "finnsheep", "gulf_coast", "hampshire",
        "icelandic_sheep", "jacob", "katahdin", "lincoln", "merino", "navajo_churro", "oxford",
        "polypay", "rambouillet", "romney", "shetland_sheep", "shropshire", "southdown", "st_croix",
        "suffolk", "texel", "tunis",
    }),
    "chicken": frozenset({
        "ameraucana", "ancona", "araucana", "australorp", "barnevelder", "brahma", "buckeye",
        "buttercup", "campine", "chantecler", "chicken_andalusian", "chicken_spanish", "cochin",
        "cornish", "cornish_cross", "crevecoeur", "cubalaya", "delaware", "dominique", "dorking",
        "easter_egger", "faverolles", "hamburg", "holland", "houdan", "java", "jersey_giant",
        "la_fleche", "lakenvelder", "langshan", "leghorn", "malay", "marans", "minorca",
        "modern_game", "naked_neck", "new_hampshire", "old_english_game", "orpington", "phoenix",
        "plymouth_rock", "polish", "rhode_island_red", "rhode_island_white", "sebright", "silkie",
        "sultan", "sumatra", "sussex", "welsummer", "wyandotte", "yokohama",
    }),
    "pig": frozenset({
        "berkshire", "chester_white", "duroc", "gloucestershire_old_spots", "guinea_hog",
        "hereford_hog", "landrace", "large_black", "mangalitsa", "meishan", "mulefoot", "ossabaw",
        "pig_hampshire", "red_wattle", "spotted", "tamworth", "yorkshire",
    }),
    "horse": frozenset({
        "andalusian", "appaloosa", "arabian", "belgian", "clydesdale", "fjord", "friesian",
        "gypsy_vanner", "haflinger", "icelandic_horse", "miniature", "missouri_fox_trotter",
        "morgan", "mustang", "paint", "paso_fino", "percheron", "quarter_horse", "rocky_mountain",
        "saddlebred", "shetland_pony", "shire", "standardbred", "tennessee_walker", "thoroughbred",
        "warmblood", "welsh_pony",
    }),
    "pet": frozenset(),
}
SPECIES_BREEDS["dairy_cow"] = frozenset({
    "ayrshire", "brown_swiss", "canadienne", "danish_red", "dutch_belted", "guernsey",
    "holstein", "illawarra", "jersey", "kerry", "milking_shorthorn", "montbeliarde",
    "normande", "norwegian_red", "randall", "swedish_red",
})
_AMOUNT = re.compile(r"^(?:[1-9]\d{0,8}|0)(?:\.\d{1,2})?$")
_SIGNED_AMOUNT = re.compile(r"^-?(?:[1-9]\d{0,8}|0)(?:\.\d{1,2})?$")
_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_WHEN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|\+00:00)$")


class LivestockPostgresError(RuntimeError):
    pass


def ssh_psql(sql: str) -> str:
    completed = subprocess.run(
        [
            "ssh",
            "SSH-Dev",
            "docker",
            "exec",
            "-i",
            "openclaw-ai-postgres-dev",
            "psql",
            "-U",
            "ranchos_dev_runtime",
            "-d",
            "ranchos_livestock_dev",
            "-v",
            "ON_ERROR_STOP=1",
            "-A",
            "-t",
            "-q",
        ],
        input=sql,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip().splitlines()
        message = next((line for line in reversed(detail) if line.startswith("ERROR:")), "livestock database query failed")
        raise LivestockPostgresError(message.removeprefix("ERROR:").strip())
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def require_uuid(value: str) -> str:
    if not _UUID.match(value):
        raise LivestockPostgresError("animal reference is not valid")
    return value


class LivestockPostgresRecords:
    def __init__(self, runner=ssh_psql):
        self._runner = runner

    def animals(self) -> list[dict[str, object]]:
        raw = self._runner(_session(self._list_sql()))
        if not raw:
            return []
        parsed = json.loads(raw)
        if not isinstance(parsed, list):
            raise LivestockPostgresError("livestock database returned an unexpected animal list")
        return parsed

    def herds(self) -> list[dict[str, object]]:
        raw = self._runner(_session(self._herds_sql()))
        if not raw or raw.strip() == "development":
            return []
        parsed = json.loads(raw)
        if not isinstance(parsed, list):
            raise LivestockPostgresError("livestock database returned an unexpected herd list")
        return parsed

    def create_herd(self, name: str, notes: str = "") -> str:
        cleaned = " ".join(name.split())
        recorded_notes = notes.strip()
        if not cleaned or len(cleaned) > 80:
            raise LivestockPostgresError("herd name is required")
        if len(recorded_notes) > 2000:
            raise LivestockPostgresError("other information is too long")
        existing = self._runner(
            _session(
                "SELECT id::text FROM ranchos.livestock_herds "
                f"WHERE tenant_id = {quote(TENANT_UUID)} AND lower(name) = lower({quote(cleaned)})"
            )
        ).strip()
        if _UUID.match(existing):
            raise LivestockPostgresError("that herd name is already used")
        notes_sql = "NULL" if not recorded_notes else quote(recorded_notes)
        inserted = self._runner(_session(self._create_herd_sql(cleaned, notes_sql))).strip()
        if not _UUID.match(inserted):
            raise LivestockPostgresError("that herd name is already used")
        return inserted

    def assign_herd(self, animal_id: str, herd_id: str) -> None:
        require_uuid(animal_id)
        if not str(herd_id).strip():
            self.clear_herd(animal_id)
            return
        require_uuid(herd_id)
        self._animal_species(animal_id)
        current = self._runner(
            _session(
                "SELECT herd_id::text FROM ranchos.livestock_herd_assignments "
                f"WHERE tenant_id = {quote(TENANT_UUID)} AND animal_id = {quote(animal_id)} AND ended_at IS NULL"
            )
        ).strip()
        if _UUID.match(current) and current.lower() == herd_id.lower():
            raise LivestockPostgresError("this animal is already in that herd")
        state = self._herd_state(herd_id)
        if state == "retired":
            raise LivestockPostgresError("that herd has been retired")
        if state != "open":
            raise LivestockPostgresError("that herd was not found")
        inserted = self._runner(_session(self._assign_herd_sql(animal_id, herd_id))).strip()
        if not _UUID.match(inserted):
            raise LivestockPostgresError("that herd was not found")

    def clear_herd(self, animal_id: str) -> None:
        require_uuid(animal_id)
        self._animal_species(animal_id)
        updated = self._runner(
            _session(
                "UPDATE ranchos.livestock_herd_assignments SET ended_at = CURRENT_TIMESTAMP "
                f"WHERE tenant_id = {quote(TENANT_UUID)} AND animal_id = {quote(animal_id)} AND ended_at IS NULL "
                "RETURNING id::text"
            )
        ).strip()
        if not _UUID.match(updated):
            raise LivestockPostgresError("this animal is already unassigned")

    def retire_herd(self, herd_id: str) -> None:
        require_uuid(herd_id)
        state = self._herd_state(herd_id)
        if state == "retired":
            raise LivestockPostgresError("that herd has already been retired")
        if state != "open":
            raise LivestockPostgresError("that herd was not found")
        assigned = self._runner(
            _session(
                "SELECT COUNT(*)::text FROM ranchos.livestock_herd_assignments "
                f"WHERE tenant_id = {quote(TENANT_UUID)} AND herd_id = {quote(herd_id)} AND ended_at IS NULL"
            )
        ).strip()
        if assigned != "0":
            raise LivestockPostgresError("reassign or unassign every animal before retiring this herd")
        updated = self._runner(
            _session(
                "UPDATE ranchos.livestock_herds SET retired_at = CURRENT_TIMESTAMP "
                f"WHERE tenant_id = {quote(TENANT_UUID)} AND id = {quote(herd_id)} AND retired_at IS NULL "
                "RETURNING id::text"
            )
        ).strip()
        if not _UUID.match(updated):
            raise LivestockPostgresError("that herd was not found")

    def _herd_state(self, herd_id: str) -> str:
        raw = self._runner(
            _session(
                "SELECT CASE WHEN retired_at IS NULL THEN 'open' ELSE 'retired' END "
                "FROM ranchos.livestock_herds "
                f"WHERE tenant_id = {quote(TENANT_UUID)} AND id = {quote(herd_id)}"
            )
        ).strip()
        return raw if raw in {"open", "retired"} else ""

    def create_animal(
        self,
        display_name: str,
        species: str,
        production: str,
        breed: str,
        pet_breed: str = "",
        mix_one: str = "",
        mix_two: str = "",
        pet_species: str = "",
        pet_species_other: str = "",
    ) -> str:
        name = " ".join(display_name.split())
        if not name or len(name) > 80:
            raise LivestockPostgresError("display name is required")
        if species not in SPECIES_PRODUCTION or production not in SPECIES_PRODUCTION[species]:
            raise LivestockPostgresError("species and production type are not accepted")
        breed_code = breed.strip()
        if species == "pet":
            breed_sql = "NULL"
            pet_sql, one_sql, two_sql = self._pet_breed_sql(pet_breed, mix_one, mix_two)
            species_sql, other_sql = self._pet_species_sql(pet_species, pet_species_other)
        elif breed_code and breed_code not in SPECIES_BREEDS.get(species, frozenset()):
            raise LivestockPostgresError("breed is not accepted for that species")
        else:
            breed_sql = "NULL" if not breed_code else quote(breed_code)
            pet_sql, one_sql, two_sql = "NULL", "NULL", "NULL"
            species_sql, other_sql = "NULL", "NULL"
        inserted = self._runner(
            _session(
                self._create_animal_sql(
                    name, species, production, breed_sql, pet_sql, one_sql, two_sql, species_sql, other_sql
                )
            )
        )
        if not inserted:
            raise LivestockPostgresError("the animal was not created")
        return inserted

    def assign_identifier(self, animal_id: str, kind: str, value: str) -> None:
        require_uuid(animal_id)
        if kind not in IDENTIFIER_KINDS:
            raise LivestockPostgresError("identifier kind is not accepted")
        species = self._animal_species(animal_id)
        if species == "pet" and kind not in PET_IDENTIFIER_KINDS:
            raise LivestockPostgresError("a pet identifier is a license or other")
        if species != "pet" and kind not in LIVESTOCK_IDENTIFIER_KINDS:
            raise LivestockPostgresError("that identifier kind is not used for live stock")
        normalized = value.strip()
        if not normalized:
            raise LivestockPostgresError("identifier value is required")
        self._runner(_session(self._assign_sql(animal_id, kind, normalized)))

    def retire_identifier(self, animal_id: str, identifier_id: str, reason: str) -> None:
        require_uuid(animal_id)
        require_uuid(identifier_id)
        self._require_retirement_reason(reason)
        species = self._animal_species(animal_id)
        self._require_species_retirement_reason(species, reason)
        inserted = self._runner(_session(self._retire_sql(animal_id, identifier_id, reason)))
        if not inserted:
            raise LivestockPostgresError("that identifier is already retired")

    def retire_animal(self, animal_id: str, reason: str, sale_amount: str = "", sale_on: str = "") -> None:
        require_uuid(animal_id)
        self._require_retirement_reason(reason)
        species = self._animal_species(animal_id)
        self._require_species_retirement_reason(species, reason)
        amount_sql, day_sql = self._sale_sql(reason, sale_amount, sale_on)
        inserted = self._runner(_session(self._retire_animal_sql(animal_id, reason, amount_sql, day_sql)))
        if not inserted.strip():
            raise LivestockPostgresError("that animal is already retired")

    def _sale_sql(self, reason: str, sale_amount: str, sale_on: str) -> tuple[str, str]:
        amount = sale_amount.strip()
        day = sale_on.strip()
        if reason != "sold":
            if amount or day:
                raise LivestockPostgresError("only a sold animal has a sale date and amount")
            return "NULL", "NULL"
        if not amount or not day:
            raise LivestockPostgresError("a sale needs a date and an amount")
        if not _AMOUNT.match(amount):
            raise LivestockPostgresError("sale amount must be a number zero or greater")
        number = Decimal(amount)
        if number < 0:
            raise LivestockPostgresError("sale amount must be a number zero or greater")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
            raise LivestockPostgresError("sale date is not accepted")
        return format(number, "f"), f"DATE {quote(day)}"

    def update_classification(self, animal_id: str, production: str, breed: str) -> None:
        require_uuid(animal_id)
        species = self._animal_species(animal_id)
        if species == "pet":
            raise LivestockPostgresError("a pet does not have a livestock production type or breed")
        if production not in SPECIES_PRODUCTION[species]:
            raise LivestockPostgresError("production type is not accepted")
        breed_code = breed.strip()
        if breed_code and breed_code not in SPECIES_BREEDS.get(species, frozenset()):
            raise LivestockPostgresError("breed is not accepted for that species")
        breed_sql = "NULL" if not breed_code else quote(breed_code)
        updated = self._runner(_session(self._classification_sql(animal_id, species, production, breed_sql)))
        if updated.strip().lower() != animal_id.lower():
            raise LivestockPostgresError("the animal was not found")

    def _require_retirement_reason(self, reason: str) -> None:
        if reason not in RETIREMENT_REASONS:
            raise LivestockPostgresError("retirement reason is not accepted")

    def _require_species_retirement_reason(self, species: str, reason: str) -> None:
        if species == "pet" and reason not in PET_RETIREMENT_REASONS:
            raise LivestockPostgresError("a pet retirement reason is rehomed, deceased, or lost")
        if species != "pet" and reason not in LIVESTOCK_RETIREMENT_REASONS:
            raise LivestockPostgresError("a livestock retirement reason is deceased, processed, or sold")

    def _assert_open_for_records(self, animal_id: str) -> None:
        raw = self._runner(
            _session(
                "SELECT reason FROM ranchos.livestock_animal_retirements "
                f"WHERE tenant_id = {quote(TENANT_UUID)} AND animal_id = {quote(animal_id)}"
            )
        ).strip()
        if raw in RETIREMENT_REASONS or raw in {"replaced", "invalid", "duplicate"}:
            raise LivestockPostgresError(
                "a retired animal cannot receive care, feed, lifecycle, or cost records"
            )

    def record_care(self, animal_id: str, event_type: str, occurred_at: str, confirmed: bool) -> None:
        require_uuid(animal_id)
        if event_type not in CARE_TYPES:
            raise LivestockPostgresError("care event is not accepted")
        if not _WHEN.match(occurred_at):
            raise LivestockPostgresError("care time is not accepted")
        if event_type in HIGH_IMPACT_CARE and not confirmed:
            raise LivestockPostgresError("surgery, vaccination, and medication require confirmation")
        self._assert_open_for_records(animal_id)
        self._runner(_session(self._care_sql(animal_id, event_type, occurred_at, confirmed)))

    def record_consumption(
        self,
        animal_id: str,
        input_type: str,
        quantity: str,
        unit: str,
        observed_at: str,
        supplier: str,
        batch: str,
        frequency: str = "daily",
    ) -> None:
        require_uuid(animal_id)
        if input_type not in INPUT_TYPES:
            raise LivestockPostgresError("input type is not accepted")
        if unit not in INPUT_UNITS:
            raise LivestockPostgresError("input unit is not accepted")
        if frequency not in FEED_FREQUENCIES:
            raise LivestockPostgresError("feed frequency is not accepted")
        if not _WHEN.match(observed_at):
            raise LivestockPostgresError("consumption time is not accepted")
        amount = _positive(quantity, "quantity")
        self._assert_open_for_records(animal_id)
        self._runner(
            _session(
                self._consumption_sql(
                    animal_id, input_type, amount, unit, observed_at, supplier.strip(), batch.strip(), frequency
                )
            )
        )

    def record_cost(
        self,
        animal_id: str,
        amount: str,
        finance_reference: str,
        confirmed: bool,
        frequency: str = "",
        feed_type: str = "",
    ) -> None:
        require_uuid(animal_id)
        if not confirmed:
            raise LivestockPostgresError("a cost attribution requires confirmation")
        value = _nonzero(amount, "amount")
        reference = finance_reference.strip()
        period = frequency.strip()
        kind = feed_type.strip()
        if period and period not in FEED_FREQUENCIES:
            raise LivestockPostgresError("feed frequency is not accepted")
        if kind and kind not in INPUT_TYPES:
            raise LivestockPostgresError("feed type is not accepted")
        self._assert_open_for_records(animal_id)
        self._runner(_session(self._cost_sql(animal_id, value, reference, period, kind)))

    def record_lifecycle(self, animal_id: str, event_type: str, occurred_at: str) -> None:
        require_uuid(animal_id)
        if event_type not in LIFECYCLE_TYPES:
            raise LivestockPostgresError("lifecycle event is not accepted")
        if not _WHEN.match(occurred_at):
            raise LivestockPostgresError("lifecycle time is not accepted")
        self._assert_open_for_records(animal_id)
        inserted = self._runner(_session(self._lifecycle_sql(animal_id, event_type, occurred_at)))
        if not inserted:
            raise LivestockPostgresError("routine lifecycle events must be later than the latest event for this animal")

    def _list_sql(self) -> str:
        return """
        SELECT COALESCE(json_agg(animal ORDER BY animal->>'display_name'), '[]'::json)::text
        FROM (
          SELECT json_build_object(
            'animal_id', a.id,
            'display_name', a.display_name,
            'species_code', a.species_code,
            'production_type_code', a.production_type_code,
            'breed_code', a.breed_code,
            'pet_breed', a.pet_breed,
            'pet_mix_one', a.pet_mix_one,
            'pet_mix_two', a.pet_mix_two,
            'pet_species', a.pet_species,
            'pet_species_other', a.pet_species_other,
            'lifecycle_status', 'active',
            'retirement_reason', (
              SELECT r.reason FROM ranchos.livestock_animal_retirements r
              WHERE r.tenant_id = a.tenant_id AND r.animal_id = a.id
              LIMIT 1
            ),
            'sale_amount', (
              SELECT r.sale_amount::text FROM ranchos.livestock_animal_retirements r
              WHERE r.tenant_id = a.tenant_id AND r.animal_id = a.id
              LIMIT 1
            ),
            'sale_on', (
              SELECT to_char(r.sale_on, 'YYYY-MM-DD') FROM ranchos.livestock_animal_retirements r
              WHERE r.tenant_id = a.tenant_id AND r.animal_id = a.id
              LIMIT 1
            ),
            'retired_at', (
              SELECT to_char(r.retired_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
              FROM ranchos.livestock_animal_retirements r
              WHERE r.tenant_id = a.tenant_id AND r.animal_id = a.id
              LIMIT 1
            ),
            'identifiers', (
              SELECT COALESCE(json_agg(json_build_object(
                'id', i.id,
                'kind', i.identifier_type,
                'value', i.normalized_value,
                'retirement_reason', r.reason,
                'retired_at', to_char(r.retired_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
              ) ORDER BY i.effective_at, i.id), '[]'::json)
              FROM ranchos.animal_identifiers i
              LEFT JOIN ranchos.animal_identifier_retirements r
                ON r.tenant_id = i.tenant_id AND r.identifier_id = i.id
              WHERE i.tenant_id = a.tenant_id AND i.animal_id = a.id
            ),
            'lifecycle_events', (
              SELECT COALESCE(json_agg(json_build_object(
                'id', e.id,
                'type', e.event_type,
                'occurred_at', to_char(e.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
              ) ORDER BY e.occurred_at, e.id), '[]'::json)
              FROM ranchos.livestock_lifecycle_events e
              WHERE e.tenant_id = a.tenant_id AND e.animal_id = a.id AND e.supersedes_event_id IS NULL
            ),
            'care_events', (
              SELECT COALESCE(json_agg(json_build_object(
                'id', c.id,
                'type', c.event_type,
                'occurred_at', to_char(c.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
              ) ORDER BY c.occurred_at, c.id), '[]'::json)
              FROM ranchos.livestock_care_events c
              WHERE c.tenant_id = a.tenant_id AND c.animal_id = a.id
            ),
            'consumptions', (
              SELECT COALESCE(json_agg(json_build_object(
                'id', n.id,
                'input_type', n.input_type,
                'quantity', n.quantity,
                'unit', n.unit_code,
                'observed_at', to_char(n.observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                'supplier', n.supplier_reference,
                'batch', n.batch_reference,
                'frequency', n.frequency_code
              ) ORDER BY n.observed_at, n.id), '[]'::json)
              FROM ranchos.livestock_input_consumption n
              WHERE n.tenant_id = a.tenant_id AND n.animal_id = a.id
            ),
            'costs', (
              SELECT COALESCE(json_agg(json_build_object(
                'id', k.id,
                'amount', k.amount,
                'currency', k.currency_code,
                'basis', k.basis_code,
                'finance_reference', k.finance_reference,
                'frequency', k.frequency_code,
                'feed_type', k.feed_type,
                'recorded_at', to_char(k.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
              ) ORDER BY k.created_at, k.id), '[]'::json)
              FROM ranchos.livestock_cost_attributions k
              WHERE k.tenant_id = a.tenant_id AND k.animal_id = a.id
            ),
            'herd_id', (
              SELECT h.id
              FROM ranchos.livestock_herd_assignments s
              JOIN ranchos.livestock_herds h
                ON h.tenant_id = s.tenant_id AND h.id = s.herd_id
              WHERE s.tenant_id = a.tenant_id AND s.animal_id = a.id AND s.ended_at IS NULL
              LIMIT 1
            ),
            'herd_name', (
              SELECT h.name
              FROM ranchos.livestock_herd_assignments s
              JOIN ranchos.livestock_herds h
                ON h.tenant_id = s.tenant_id AND h.id = s.herd_id
              WHERE s.tenant_id = a.tenant_id AND s.animal_id = a.id AND s.ended_at IS NULL
              LIMIT 1
            ),
            'herd_started_at', (
              SELECT to_char(s.started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
              FROM ranchos.livestock_herd_assignments s
              WHERE s.tenant_id = a.tenant_id AND s.animal_id = a.id AND s.ended_at IS NULL
              LIMIT 1
            ),
            'provenance', json_build_object('origin', 'live', 'source_type', a.provenance_source_type)
          ) AS animal
          FROM ranchos.livestock_animals a
        ) listed
        """

    def _herds_sql(self) -> str:
        return f"""
        SELECT COALESCE(
          json_agg(json_build_object(
            'id', h.id,
            'name', h.name,
            'notes', COALESCE(h.notes, ''),
            'retired_at', to_char(h.retired_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
          ) ORDER BY lower(h.name), h.id),
          '[]'::json
        )::text
        FROM ranchos.livestock_herds h
        WHERE h.tenant_id = {quote(TENANT_UUID)}
        """

    def _create_herd_sql(self, name: str, notes_sql: str) -> str:
        return f"""
        INSERT INTO ranchos.livestock_herds (
          tenant_id, id, name, notes,
          provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
          created_by_user_id
        ) VALUES (
          {quote(TENANT_UUID)}, gen_random_uuid(), {quote(name)}, {notes_sql},
          'ranch_record', gen_random_uuid()::text, 'read-model-v1', CURRENT_TIMESTAMP,
          {quote(USER_UUID)}
        )
        RETURNING id::text
        """

    def _assign_herd_sql(self, animal_id: str, herd_id: str) -> str:
        return f"""
        WITH closed AS (
          UPDATE ranchos.livestock_herd_assignments
          SET ended_at = CURRENT_TIMESTAMP
          WHERE tenant_id = {quote(TENANT_UUID)}
            AND animal_id = {quote(animal_id)}
            AND ended_at IS NULL
          RETURNING id
        )
        INSERT INTO ranchos.livestock_herd_assignments (
          tenant_id, id, animal_id, herd_id, started_at,
          provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
          created_by_user_id
        )
        SELECT
          {quote(TENANT_UUID)}, gen_random_uuid(), {quote(animal_id)}, {quote(herd_id)}, CURRENT_TIMESTAMP,
          'ranch_record', gen_random_uuid()::text, 'read-model-v1', CURRENT_TIMESTAMP,
          {quote(USER_UUID)}
        WHERE EXISTS (
          SELECT 1 FROM ranchos.livestock_herds
          WHERE tenant_id = {quote(TENANT_UUID)} AND id = {quote(herd_id)}
        )
        AND (SELECT COUNT(*) FROM closed) >= 0
        RETURNING id::text
        """

    def _pet_breed_sql(self, pet_breed: str, mix_one: str, mix_two: str) -> tuple[str, str, str]:
        breed = " ".join(pet_breed.split())
        first = " ".join(mix_one.split())
        second = " ".join(mix_two.split())
        if breed == "mixed" or (first and second):
            if not first or not second or len(first) > 80 or len(second) > 80:
                raise LivestockPostgresError("a mixed pet needs both breeds")
            return quote("mixed"), quote(first), quote(second)
        if breed:
            if len(breed) > 80:
                raise LivestockPostgresError("breed name is too long")
            return quote(breed), "NULL", "NULL"
        return "NULL", "NULL", "NULL"

    def _pet_species_sql(self, pet_species: str, pet_species_other: str) -> tuple[str, str]:
        kind = pet_species.strip()
        other = " ".join(pet_species_other.split())
        if kind not in {"dog", "cat", "bird", "reptile", "other"}:
            raise LivestockPostgresError("a pet species is dog, cat, bird, reptile, or other")
        if kind == "other":
            if not other or len(other) > 80:
                raise LivestockPostgresError("enter the other pet species")
            return quote(kind), quote(other)
        if other:
            raise LivestockPostgresError("only an other pet species is typed")
        return quote(kind), "NULL"

    def _create_animal_sql(
        self,
        name: str,
        species: str,
        production: str,
        breed_sql: str,
        pet_sql: str,
        mix_one_sql: str,
        mix_two_sql: str,
        pet_species_sql: str,
        pet_species_other_sql: str,
    ) -> str:
        return f"""
        INSERT INTO ranchos.livestock_animals (
          tenant_id, id, display_name, species_code, production_type_code, breed_code, status,
          pet_breed, pet_mix_one, pet_mix_two, pet_species, pet_species_other,
          provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
          created_by_user_id
        ) VALUES (
          {quote(TENANT_UUID)}, gen_random_uuid(), {quote(name)}, {quote(species)}, {quote(production)}, {breed_sql}, 'active',
          {pet_sql}, {mix_one_sql}, {mix_two_sql}, {pet_species_sql}, {pet_species_other_sql},
          'ranch_record', gen_random_uuid()::text, 'read-model-v1', CURRENT_TIMESTAMP,
          {quote(USER_UUID)}
        )
        RETURNING id::text
        """

    def _assign_sql(self, animal_id: str, kind: str, value: str) -> str:
        return f"""
        INSERT INTO ranchos.animal_identifiers (
          tenant_id, id, animal_id, identifier_type, normalized_value, effective_at,
          provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
          created_by_user_id
        ) VALUES (
          {quote(TENANT_UUID)}, gen_random_uuid(), {quote(animal_id)}, {quote(kind)}, {quote(value)}, CURRENT_TIMESTAMP,
          'ranch_record', gen_random_uuid()::text, 'read-model-v1', CURRENT_TIMESTAMP,
          {quote(USER_UUID)}
        )
        RETURNING id::text
        """

    def _retire_sql(self, animal_id: str, identifier_id: str, reason: str) -> str:
        return f"""
        INSERT INTO ranchos.animal_identifier_retirements (
          tenant_id, id, identifier_id, reason, retired_at,
          provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
          created_by_user_id
        )
        SELECT {quote(TENANT_UUID)}, gen_random_uuid(), i.id, {quote(reason)}, CURRENT_TIMESTAMP,
               'ranch_record', gen_random_uuid()::text, 'read-model-v1', CURRENT_TIMESTAMP, {quote(USER_UUID)}
        FROM ranchos.animal_identifiers i
        WHERE i.tenant_id = {quote(TENANT_UUID)}
          AND i.animal_id = {quote(animal_id)}
          AND i.id = {quote(identifier_id)}
          AND NOT EXISTS (
            SELECT 1 FROM ranchos.animal_identifier_retirements r
            WHERE r.tenant_id = i.tenant_id AND r.identifier_id = i.id
          )
        RETURNING id::text
        """

    def _retire_animal_sql(self, animal_id: str, reason: str, amount_sql: str, day_sql: str) -> str:
        return f"""
        INSERT INTO ranchos.livestock_animal_retirements (
          tenant_id, id, animal_id, reason, retired_at, sale_amount, sale_on,
          provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
          created_by_user_id
        )
        SELECT {quote(TENANT_UUID)}, gen_random_uuid(), a.id, {quote(reason)}, CURRENT_TIMESTAMP, {amount_sql}, {day_sql},
               'ranch_record', gen_random_uuid()::text, 'read-model-v1', CURRENT_TIMESTAMP, {quote(USER_UUID)}
        FROM ranchos.livestock_animals a
        WHERE a.tenant_id = {quote(TENANT_UUID)}
          AND a.id = {quote(animal_id)}
          AND NOT EXISTS (
            SELECT 1 FROM ranchos.livestock_animal_retirements retired_animal
            WHERE retired_animal.tenant_id = a.tenant_id AND retired_animal.animal_id = a.id
          )
        RETURNING id::text
        """

    def _classification_sql(self, animal_id: str, species: str, production: str, breed_sql: str) -> str:
        return f"""
        UPDATE ranchos.livestock_animals
        SET production_type_code = {quote(production)}, breed_code = {breed_sql}
        WHERE tenant_id = {quote(TENANT_UUID)}
          AND id = {quote(animal_id)}
          AND species_code = {quote(species)}
          AND species_code <> 'pet'
        RETURNING id::text
        """

    def _lifecycle_sql(self, animal_id: str, event_type: str, occurred_at: str) -> str:
        when = quote(occurred_at)
        return f"""
        INSERT INTO ranchos.livestock_lifecycle_events (
          tenant_id, id, animal_id, event_type, occurred_at,
          provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
          created_by_user_id
        )
        SELECT {quote(TENANT_UUID)}, gen_random_uuid(), {quote(animal_id)}, {quote(event_type)}, {when}::timestamptz,
               'ranch_record', gen_random_uuid()::text, 'read-model-v1', CURRENT_TIMESTAMP, {quote(USER_UUID)}
        WHERE EXISTS (
          SELECT 1 FROM ranchos.livestock_animals a
          WHERE a.tenant_id = {quote(TENANT_UUID)} AND a.id = {quote(animal_id)}
        )
        AND NOT EXISTS (
          SELECT 1 FROM ranchos.livestock_lifecycle_events e
          WHERE e.tenant_id = {quote(TENANT_UUID)}
            AND e.animal_id = {quote(animal_id)}
            AND e.supersedes_event_id IS NULL
            AND e.occurred_at >= {when}::timestamptz
        )
        RETURNING id::text
        """

    def _care_sql(self, animal_id: str, event_type: str, occurred_at: str, confirmed: bool) -> str:
        confirmed_sql = "CURRENT_TIMESTAMP" if confirmed else "NULL"
        return f"""
        INSERT INTO ranchos.livestock_care_events (
          tenant_id, id, animal_id, event_type, occurred_at, confirmed_at,
          provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
          created_by_user_id
        ) VALUES (
          {quote(TENANT_UUID)}, gen_random_uuid(), {quote(animal_id)}, {quote(event_type)}, {quote(occurred_at)}::timestamptz,
          {confirmed_sql},
          'ranch_record', gen_random_uuid()::text, 'read-model-v1', CURRENT_TIMESTAMP, {quote(USER_UUID)}
        )
        RETURNING id::text
        """

    def _consumption_sql(
        self,
        animal_id: str,
        input_type: str,
        quantity: str,
        unit: str,
        observed_at: str,
        supplier: str,
        batch: str,
        frequency: str,
    ) -> str:
        supplier_sql = "NULL" if not supplier else quote(supplier)
        batch_sql = "NULL" if not batch else quote(batch)
        return f"""
        INSERT INTO ranchos.livestock_input_consumption (
          tenant_id, id, animal_id, input_type, quantity, unit_code, observed_at,
          supplier_reference, batch_reference, frequency_code,
          provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
          created_by_user_id
        ) VALUES (
          {quote(TENANT_UUID)}, gen_random_uuid(), {quote(animal_id)}, {quote(input_type)}, {quantity}, {quote(unit)},
          {quote(observed_at)}::timestamptz, {supplier_sql}, {batch_sql}, {quote(frequency)},
          'ranch_record', gen_random_uuid()::text, 'read-model-v1', CURRENT_TIMESTAMP, {quote(USER_UUID)}
        )
        RETURNING id::text
        """

    def _cost_sql(self, animal_id: str, amount: str, finance_reference: str, frequency: str, feed_type: str) -> str:
        reference_sql = "NULL" if not finance_reference else quote(finance_reference)
        frequency_sql = "NULL" if not frequency else quote(frequency)
        feed_sql = "NULL" if not feed_type else quote(feed_type)
        return f"""
        INSERT INTO ranchos.livestock_cost_attributions (
          tenant_id, id, animal_id, amount, currency_code, basis_code, finance_reference, frequency_code, feed_type,
          confirmed_at,
          provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
          created_by_user_id
        ) VALUES (
          {quote(TENANT_UUID)}, gen_random_uuid(), {quote(animal_id)}, {amount}, 'USD', 'per_animal', {reference_sql},
          {frequency_sql}, {feed_sql}, CURRENT_TIMESTAMP,
          'ranch_record', gen_random_uuid()::text, 'read-model-v1', CURRENT_TIMESTAMP, {quote(USER_UUID)}
        )
        RETURNING id::text
        """

    def _animal_species(self, animal_id: str) -> str:
        raw = self._runner(
            _session(
                "SELECT species_code FROM ranchos.livestock_animals "
                f"WHERE tenant_id = {quote(TENANT_UUID)} AND id = {quote(animal_id)}"
            )
        )
        species = raw.strip()
        if species not in SPECIES_PRODUCTION:
            raise LivestockPostgresError("the animal was not found")
        return species


def _nonzero(value: str, label: str) -> str:
    text = value.strip()
    if not _SIGNED_AMOUNT.match(text):
        raise LivestockPostgresError(f"{label} must be a number other than zero")
    try:
        number = Decimal(text)
    except InvalidOperation as error:
        raise LivestockPostgresError(f"{label} must be a number other than zero") from error
    if number == 0:
        raise LivestockPostgresError(f"{label} must be a number other than zero")
    return format(number, "f")


def _positive(value: str, label: str) -> str:
    text = value.strip()
    if not _AMOUNT.match(text):
        raise LivestockPostgresError(f"{label} must be a positive amount")
    try:
        number = Decimal(text)
    except InvalidOperation as error:
        raise LivestockPostgresError(f"{label} must be a positive amount") from error
    if number <= 0:
        raise LivestockPostgresError(f"{label} must be a positive amount")
    return format(number, "f")


def _session(statement: str) -> str:
    return f"""
    SELECT set_config('ranchos.tenant_id', {quote(TENANT_UUID)}, false);
    SELECT set_config('ranchos.principal_id', {quote(PRINCIPAL_UUID)}, false);
    SELECT set_config('ranchos.environment', 'development', false);
    {statement}
    """


def envelope(animals: list[dict[str, object]], herds: list[dict[str, object]] | None = None) -> dict[str, object]:
    stamped = []
    for animal in animals:
        row = dict(animal)
        identifiers = row.get("identifiers")
        if isinstance(identifiers, list):
            active = next((item for item in identifiers if isinstance(item, dict) and not item.get("retirement_reason")), None)
            if isinstance(active, dict):
                row["identifier"] = {"kind": active.get("kind"), "value": active.get("value")}
        row["provenance"] = {"origin": "live", "source_type": "ranch_record"}
        stamped.append(row)
    return {
        "api_version": "v1",
        "operation": "animal_list",
        "origin": "live",
        "body": {"herd_count": len(stamped), "animals": stamped, "herds": herds or []},
    }


def occurred_at_stamp(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
