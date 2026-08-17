import { chmodSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { DatabaseSync, StatementSync } from "node:sqlite";
import { openNodeSqliteDatabase } from "openclaw/plugin-sdk/sqlite-runtime";
import type {
  TrustedRecordAccessPolicy,
  TrustedRecordAuditEvent,
  TrustedRecordAuditSink,
  TrustedRecordPolicySource,
} from "./access.js";
import {
  configureSqliteWalMaintenance,
  type SqliteWalMaintenance,
  validateTrustedRecordsSqliteRuntime,
} from "./sqlite-runtime.js";

type PolicyRow = {
  policy_id: string;
  owner_id: string;
  read_actor_ids_json: string;
  write_actor_ids_json: string;
};

type AuditRow = {
  occurred_at: string;
  actor_id: string;
  action: TrustedRecordAuditEvent["action"];
  record_id: string;
  decision: TrustedRecordAuditEvent["decision"];
  policy_id: string;
  reason: TrustedRecordAuditEvent["reason"];
};

type Statements = {
  insertPolicy: StatementSync;
  selectPolicy: StatementSync;
  insertAudit: StatementSync;
  selectAudit: StatementSync;
  selectAuditByRecord: StatementSync;
};

export type SqliteTrustedRecordSecurityStore = TrustedRecordPolicySource &
  TrustedRecordAuditSink & {
    register: (policy: TrustedRecordAccessPolicy) => void;
    events: (recordId?: string) => TrustedRecordAuditEvent[];
    close: () => void;
  };

function parseActorIds(raw: string): Set<string> {
  const parsed: unknown = JSON.parse(raw);
  if (!Array.isArray(parsed) || parsed.some((value) => typeof value !== "string")) {
    throw new Error("stored trusted-record policy actor IDs are invalid");
  }
  return new Set(parsed);
}

function rowToPolicy(row: PolicyRow): TrustedRecordAccessPolicy {
  return {
    id: row.policy_id,
    ownerId: row.owner_id,
    readActorIds: parseActorIds(row.read_actor_ids_json),
    writeActorIds: parseActorIds(row.write_actor_ids_json),
  };
}

function rowToAuditEvent(row: AuditRow): TrustedRecordAuditEvent {
  return {
    occurredAt: row.occurred_at,
    actorId: row.actor_id,
    action: row.action,
    recordId: row.record_id,
    decision: row.decision,
    policyId: row.policy_id,
    reason: row.reason,
  };
}

function initialize(db: DatabaseSync): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS trusted_record_access_policies (
      policy_id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL,
      read_actor_ids_json TEXT NOT NULL,
      write_actor_ids_json TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS trusted_record_audit_events (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      occurred_at TEXT NOT NULL,
      actor_id TEXT NOT NULL,
      action TEXT NOT NULL,
      record_id TEXT NOT NULL,
      decision TEXT NOT NULL,
      policy_id TEXT NOT NULL,
      reason TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS trusted_record_audit_by_record
      ON trusted_record_audit_events(record_id, sequence);
  `);
}

function createStatements(db: DatabaseSync): Statements {
  return {
    insertPolicy: db.prepare(`
      INSERT INTO trusted_record_access_policies (
        policy_id, owner_id, read_actor_ids_json, write_actor_ids_json
      ) VALUES (?, ?, ?, ?)
    `),
    selectPolicy: db.prepare(`
      SELECT policy_id, owner_id, read_actor_ids_json, write_actor_ids_json
      FROM trusted_record_access_policies WHERE policy_id = ?
    `),
    insertAudit: db.prepare(`
      INSERT INTO trusted_record_audit_events (
        occurred_at, actor_id, action, record_id, decision, policy_id, reason
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    `),
    selectAudit: db.prepare(`
      SELECT occurred_at, actor_id, action, record_id, decision, policy_id, reason
      FROM trusted_record_audit_events ORDER BY sequence
    `),
    selectAuditByRecord: db.prepare(`
      SELECT occurred_at, actor_id, action, record_id, decision, policy_id, reason
      FROM trusted_record_audit_events WHERE record_id = ? ORDER BY sequence
    `),
  };
}

export function createSqliteTrustedRecordSecurityStore(params: {
  path: string;
}): SqliteTrustedRecordSecurityStore {
  validateTrustedRecordsSqliteRuntime();
  mkdirSync(dirname(params.path), { recursive: true, mode: 0o700 });
  const db = openNodeSqliteDatabase(params.path);
  chmodSync(params.path, 0o600);
  const walMaintenance: SqliteWalMaintenance = configureSqliteWalMaintenance(db);
  initialize(db);
  const statements = createStatements(db);

  return {
    register(policy) {
      statements.insertPolicy.run(
        policy.id,
        policy.ownerId,
        JSON.stringify([...policy.readActorIds].toSorted()),
        JSON.stringify([...policy.writeActorIds].toSorted()),
      );
    },
    get(policyId) {
      const row = statements.selectPolicy.get(policyId) as PolicyRow | undefined;
      if (!row) {
        throw new Error(`policy not found: ${policyId}`);
      }
      return rowToPolicy(row);
    },
    append(event) {
      statements.insertAudit.run(
        event.occurredAt,
        event.actorId,
        event.action,
        event.recordId,
        event.decision,
        event.policyId,
        event.reason,
      );
    },
    events(recordId) {
      const rows = (
        recordId ? statements.selectAuditByRecord.all(recordId) : statements.selectAudit.all()
      ) as AuditRow[];
      return rows.map(rowToAuditEvent);
    },
    close() {
      walMaintenance.close();
      db.close();
    },
  };
}
