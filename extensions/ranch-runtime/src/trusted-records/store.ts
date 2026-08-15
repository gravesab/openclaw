import type { TrustedRecord, TrustedRecordCorrection } from "./types.js";

export type TrustedRecordStore = {
  create: (record: TrustedRecord) => TrustedRecord;
  get: (recordId: string) => TrustedRecord;
  getRevision: (revisionId: string) => TrustedRecord;
  history: (recordId: string) => TrustedRecord[];
  currentRecords: () => TrustedRecord[];
  dependents: (recordId: string) => TrustedRecord[];
  correct: (recordId: string, correction: TrustedRecordCorrection) => TrustedRecord;
  archive: (recordId: string, revisionId: string, reason: string) => TrustedRecord;
  addReference: (params: {
    recordId: string;
    targetRecordId: string;
    revisionId: string;
    relationshipType: TrustedRecord["relationships"][number]["type"];
    source: TrustedRecord["source"]["type"];
    reason: string;
  }) => TrustedRecord;
  resolveInboxCapture: (params: {
    captureId: string;
    resolvedRecord: TrustedRecord;
    captureRevisionId: string;
    reason: string;
    captureChanges: TrustedRecordCorrection["changes"];
  }) => { resolvedRecord: TrustedRecord; capture: TrustedRecord };
};
