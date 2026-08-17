import type { DatabaseSync } from "node:sqlite";
import { openNodeSqliteDatabase } from "openclaw/plugin-sdk/sqlite-runtime";

type SqliteVersion = {
  major: number;
  minor: number;
  patch: number;
};

export type SqliteWalMaintenance = {
  checkpoint: () => boolean;
  close: () => boolean;
};

function parseSqliteVersion(value: string): SqliteVersion | undefined {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(value.trim());

  if (!match) {
    return undefined;
  }

  const major = Number.parseInt(match[1] ?? "", 10);
  const minor = Number.parseInt(match[2] ?? "", 10);
  const patch = Number.parseInt(match[3] ?? "", 10);

  if (![major, minor, patch].every(Number.isSafeInteger)) {
    return undefined;
  }

  return { major, minor, patch };
}

function compareVersion(left: SqliteVersion, right: SqliteVersion): number {
  if (left.major !== right.major) {
    return left.major - right.major;
  }

  if (left.minor !== right.minor) {
    return left.minor - right.minor;
  }

  return left.patch - right.patch;
}

function isWalSafeVersion(value: string): boolean {
  const version = parseSqliteVersion(value);

  if (!version) {
    return false;
  }

  if (compareVersion(version, { major: 3, minor: 51, patch: 3 }) >= 0) {
    return true;
  }

  return (
    (version.major === 3 && version.minor === 50 && version.patch >= 7) ||
    (version.major === 3 && version.minor === 44 && version.patch >= 6)
  );
}

let validatedSqliteRuntime = false;

export function validateTrustedRecordsSqliteRuntime(): void {
  if (validatedSqliteRuntime) {
    return;
  }

  try {
    const probe = openNodeSqliteDatabase(":memory:");

    try {
      const row = probe.prepare("SELECT sqlite_version() AS version").get() as
        | { version?: unknown }
        | undefined;

      const version = typeof row?.version === "string" ? row.version : "unknown";

      if (!isWalSafeVersion(version)) {
        throw new Error(`SQLite ${version} is not approved for Trusted Records WAL storage`);
      }

      validatedSqliteRuntime = true;
    } finally {
      probe.close();
    }
  } catch (error) {
    throw new Error(`Trusted Records SQLite support is unavailable or unsafe: ${String(error)}`, {
      cause: error,
    });
  }
}

export function configureSqliteWalMaintenance(db: DatabaseSync): SqliteWalMaintenance {
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec("PRAGMA synchronous = NORMAL;");
  db.exec("PRAGMA wal_autocheckpoint = 1000;");
  db.exec("PRAGMA journal_size_limit = 67108864;");

  const checkpoint = (): boolean => {
    try {
      db.exec("PRAGMA wal_checkpoint(PASSIVE);");
      return true;
    } catch {
      return false;
    }
  };

  const interval = setInterval(checkpoint, 30 * 60 * 1000);

  interval.unref?.();

  let closed = false;

  return {
    checkpoint,

    close(): boolean {
      if (closed) {
        return true;
      }

      closed = true;
      clearInterval(interval);

      try {
        db.exec("PRAGMA wal_checkpoint(TRUNCATE);");
        return true;
      } catch {
        return false;
      }
    },
  };
}
