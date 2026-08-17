import { join } from "node:path";
import { SecureTrustedRecordService, type TrustedRecordActor } from "./access.js";
import {
  createSqliteTrustedRecordSecurityStore,
  type SqliteTrustedRecordSecurityStore,
} from "./access.sqlite.js";
import { TrustedRecordInboxService } from "./inbox.js";
import { TrustedRecordInspector } from "./inspector.js";
import { createSqliteTrustedRecordStore, type SqliteTrustedRecordStore } from "./store.sqlite.js";

export type TrustedRecordDevelopmentRuntime = {
  records: SqliteTrustedRecordStore;
  security: SqliteTrustedRecordSecurityStore;
  secureRecords: SecureTrustedRecordService;
  inbox: TrustedRecordInboxService;
  inspector: TrustedRecordInspector;
  close: () => void;
};

/**
 * Creates the isolated single-node development runtime.
 *
 * No application route calls this factory yet. Production wiring requires a
 * separate persistence, recovery, encryption, and operations review.
 */
export function createTrustedRecordDevelopmentRuntime(params: {
  dataDir: string;
  now?: () => Date;
}): TrustedRecordDevelopmentRuntime {
  const records = createSqliteTrustedRecordStore({
    path: join(params.dataDir, "trusted-records.sqlite3"),
    now: params.now,
  });
  const security = createSqliteTrustedRecordSecurityStore({
    path: join(params.dataDir, "trusted-record-security.sqlite3"),
  });
  const secureRecords = new SecureTrustedRecordService(records, security, security, params.now);
  return {
    records,
    security,
    secureRecords,
    inbox: new TrustedRecordInboxService(secureRecords),
    inspector: new TrustedRecordInspector(secureRecords),
    close() {
      security.close();
      records.close();
    },
  };
}

export function createTrustedRecordActor(params: {
  id: string;
  roles?: Iterable<string>;
}): TrustedRecordActor {
  return { id: params.id, roles: new Set(params.roles) };
}
