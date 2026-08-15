import type { SecureTrustedRecordService, TrustedRecordActor } from "./access.js";
import { parseTrustedRecord } from "./schema.js";
import type { TrustedRecord } from "./types.js";

export class TrustedRecordInboxService {
  constructor(readonly secureRecords: SecureTrustedRecordService) {}

  resolve(params: {
    actor: TrustedRecordActor;
    captureId: string;
    resolvedRecord: TrustedRecord;
    captureRevisionId: string;
    reason: string;
  }): { resolvedRecord: TrustedRecord; capture: TrustedRecord } {
    if (!params.reason.trim()) {
      throw new Error("resolution reason is required");
    }
    const capture = this.secureRecords.read(params.actor, params.captureId);
    this.secureRecords.authorize(params.actor, "correct", capture);
    if (capture.recordType !== "general.capture" || capture.lifecycle.state !== "captured") {
      throw new Error("record is not an unresolved Inbox capture");
    }
    if (params.resolvedRecord.ownerDomain === "general") {
      throw new Error("resolved records require a domain owner");
    }
    if (params.resolvedRecord.security.ownerId !== params.actor.id) {
      throw new Error("actor must own the resolved record");
    }
    const resolvedRecord = parseTrustedRecord({
      ...structuredClone(params.resolvedRecord),
      source: {
        ...params.resolvedRecord.source,
        originalRecordId: capture.id,
      },
      relationships: [
        ...params.resolvedRecord.relationships,
        {
          type: "derived_from",
          targetRecordId: capture.id,
          createdAt: params.resolvedRecord.createdAt,
          source: params.resolvedRecord.source.type,
        },
      ],
    });
    return this.secureRecords.store.resolveInboxCapture({
      captureId: capture.id,
      resolvedRecord,
      captureRevisionId: params.captureRevisionId,
      reason: params.reason,
      captureChanges: {
        lifecycle: { state: "resolved", reason: params.reason },
        relationships: [
          ...capture.relationships,
          {
            type: "related_to",
            targetRecordId: resolvedRecord.id,
            createdAt: resolvedRecord.createdAt,
            source: "user",
          },
        ],
        data: {
          ...capture.data,
          classificationStatus: "confirmed",
          resolvedRecordId: resolvedRecord.id,
        },
      },
    });
  }
}
