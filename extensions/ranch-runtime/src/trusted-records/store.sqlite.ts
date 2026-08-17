import { chmodSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { DatabaseSync, StatementSync } from "node:sqlite";
import { openNodeSqliteDatabase } from "openclaw/plugin-sdk/sqlite-runtime";
import { TrustedRecordConflictError, TrustedRecordNotFoundError } from "./errors.js";
import { parseTrustedRecord } from "./schema.js";
import {
  configureSqliteWalMaintenance,
  type SqliteWalMaintenance,
  validateTrustedRecordsSqliteRuntime,
} from "./sqlite-runtime.js";
import type { TrustedRecordStore } from "./store.js";
import type { TrustedRecord, TrustedRecordCorrection } from "./types.js";

type RecordRow = { payload_json: string };

type Statements = {
  selectCurrent: StatementSync;
  selectRevision: StatementSync;
  selectHistory: StatementSync;
  selectAllCurrent: StatementSync;
  insert: StatementSync;
  clearCurrent: StatementSync;
};

export type SqliteTrustedRecordStore = TrustedRecordStore & { close: () => void };

function cloneRecord(record: TrustedRecord): TrustedRecord {
  return structuredClone(record);
}

function parseRow(row: RecordRow | undefined, missingMessage: string): TrustedRecord {
  if (!row) {
    throw new TrustedRecordNotFoundError(missingMessage);
  }
  return parseTrustedRecord(JSON.parse(row.payload_json));
}

function createStatements(db: DatabaseSync): Statements {
  return {
    selectCurrent: db.prepare(
      "SELECT payload_json FROM trusted_record_revisions WHERE record_id = ? AND is_current = 1",
    ),
    selectRevision: db.prepare(
      "SELECT payload_json FROM trusted_record_revisions WHERE revision_id = ?",
    ),
    selectHistory: db.prepare(
      "SELECT payload_json FROM trusted_record_revisions WHERE record_id = ? ORDER BY version_number",
    ),
    selectAllCurrent: db.prepare(
      "SELECT payload_json FROM trusted_record_revisions WHERE is_current = 1 ORDER BY record_id",
    ),
    insert: db.prepare(`
      INSERT INTO trusted_record_revisions (
        record_id, revision_id, version_number, is_current, payload_json
      ) VALUES (?, ?, ?, 1, ?)
    `),
    clearCurrent: db.prepare(
      "UPDATE trusted_record_revisions SET is_current = 0 WHERE record_id = ? AND is_current = 1",
    ),
  };
}

function initialize(db: DatabaseSync): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS trusted_record_revisions (
      record_id TEXT NOT NULL,
      revision_id TEXT PRIMARY KEY,
      version_number INTEGER NOT NULL,
      is_current INTEGER NOT NULL CHECK (is_current IN (0, 1)),
      payload_json TEXT NOT NULL,
      UNIQUE (record_id, version_number)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS trusted_record_one_current_revision
      ON trusted_record_revisions(record_id) WHERE is_current = 1;
  `);
}

export function createSqliteTrustedRecordStore(params: {
  path: string;
  now?: () => Date;
}): SqliteTrustedRecordStore {
  validateTrustedRecordsSqliteRuntime();
  mkdirSync(dirname(params.path), { recursive: true, mode: 0o700 });
  const db = openNodeSqliteDatabase(params.path);
  chmodSync(params.path, 0o600);
  db.exec("PRAGMA foreign_keys = ON;");
  const walMaintenance: SqliteWalMaintenance = configureSqliteWalMaintenance(db);
  initialize(db);
  const statements = createStatements(db);
  const now = params.now ?? (() => new Date());

  const transaction = <T>(operation: () => T): T => {
    db.exec("BEGIN IMMEDIATE;");
    try {
      const result = operation();
      db.exec("COMMIT;");
      return result;
    } catch (error) {
      db.exec("ROLLBACK;");
      throw error;
    }
  };

  const insert = (record: TrustedRecord): void => {
    try {
      statements.insert.run(
        record.id,
        record.revisionId,
        record.version.number,
        JSON.stringify(record),
      );
    } catch (error) {
      throw new TrustedRecordConflictError("record or revision already exists", { cause: error });
    }
  };

  const get = (recordId: string): TrustedRecord =>
    cloneRecord(
      parseRow(
        statements.selectCurrent.get(recordId) as RecordRow | undefined,
        `record not found: ${recordId}`,
      ),
    );

  const prepareCorrection = (
    recordId: string,
    correction: TrustedRecordCorrection,
  ): TrustedRecord => {
    if (!correction.correctionReason.trim()) {
      throw new Error("correctionReason is required");
    }
    const current = get(recordId);
    const candidate = parseTrustedRecord({
      ...current,
      ...structuredClone(correction.changes),
      revisionId: correction.revisionId,
      updatedAt: now().toISOString(),
      version: {
        number: current.version.number + 1,
        previousRevisionId: current.revisionId,
        supersedesRecordId: current.version.supersedesRecordId,
        correctionReason: correction.correctionReason,
      },
    });
    return candidate;
  };

  const replaceCurrent = (record: TrustedRecord): void => {
    statements.clearCurrent.run(record.id);
    insert(record);
  };

  const store: SqliteTrustedRecordStore = {
    create(record) {
      const candidate = parseTrustedRecord(record);
      if (candidate.version.number !== 1 || candidate.version.previousRevisionId !== null) {
        throw new Error("new records must begin at version 1 without a previous revision");
      }
      transaction(() => insert(candidate));
      return cloneRecord(candidate);
    },
    get,
    getRevision(revisionId) {
      return cloneRecord(
        parseRow(
          statements.selectRevision.get(revisionId) as RecordRow | undefined,
          `revision not found: ${revisionId}`,
        ),
      );
    },
    history(recordId) {
      const rows = statements.selectHistory.all(recordId) as RecordRow[];
      if (rows.length === 0) {
        throw new TrustedRecordNotFoundError(`record not found: ${recordId}`);
      }
      return rows.map((row) => cloneRecord(parseTrustedRecord(JSON.parse(row.payload_json))));
    },
    currentRecords() {
      const rows = statements.selectAllCurrent.all() as RecordRow[];
      return rows.map((row) => cloneRecord(parseTrustedRecord(JSON.parse(row.payload_json))));
    },
    dependents(recordId) {
      get(recordId);
      return store
        .currentRecords()
        .filter(
          (candidate) =>
            candidate.provenance.inputRecordIds.includes(recordId) ||
            candidate.relationships.some(
              (relationship) => relationship.targetRecordId === recordId,
            ),
        );
    },
    correct(recordId, correction) {
      return transaction(() => {
        const candidate = prepareCorrection(recordId, correction);
        replaceCurrent(candidate);
        return cloneRecord(candidate);
      });
    },
    archive(recordId, revisionId, reason) {
      return store.correct(recordId, {
        revisionId,
        correctionReason: reason,
        changes: { lifecycle: { state: "archived", reason } },
      });
    },
    addReference(reference) {
      return transaction(() => {
        const current = get(reference.recordId);
        get(reference.targetRecordId);
        const candidate = prepareCorrection(reference.recordId, {
          revisionId: reference.revisionId,
          correctionReason: reference.reason,
          changes: {
            relationships: [
              ...current.relationships,
              {
                type: reference.relationshipType,
                targetRecordId: reference.targetRecordId,
                createdAt: now().toISOString(),
                source: reference.source,
              },
            ],
          },
        });
        replaceCurrent(candidate);
        return cloneRecord(candidate);
      });
    },
    resolveInboxCapture(resolution) {
      return transaction(() => {
        const candidate = parseTrustedRecord(resolution.resolvedRecord);
        const capture = prepareCorrection(resolution.captureId, {
          revisionId: resolution.captureRevisionId,
          correctionReason: resolution.reason,
          changes: resolution.captureChanges,
        });
        insert(candidate);
        replaceCurrent(capture);
        return { resolvedRecord: cloneRecord(candidate), capture: cloneRecord(capture) };
      });
    },
    close() {
      walMaintenance.close();
      db.close();
    },
  };
  return store;
}
