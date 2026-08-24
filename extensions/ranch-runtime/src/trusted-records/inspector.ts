import type { SecureTrustedRecordService, TrustedRecordActor } from "./access.js";

export class TrustedRecordInspector {
  constructor(readonly secureRecords: SecureTrustedRecordService) {}

  inspect(actor: TrustedRecordActor, recordId: string) {
    const current = this.secureRecords.read(actor, recordId);
    const history = this.secureRecords.store.history(recordId);
    return {
      identity: {
        id: current.id,
        recordType: current.recordType,
        ownerDomain: current.ownerDomain,
        title: current.title,
      },
      state: {
        lifecycle: current.lifecycle,
        dataState: current.dataState,
        sensitivity: current.security.sensitivity,
      },
      source: current.source,
      provenance: current.provenance,
      relationships: current.relationships,
      version: current.version,
      history: history.map((revision) => ({
        revisionId: revision.revisionId,
        number: revision.version.number,
        updatedAt: revision.updatedAt,
        correctionReason: revision.version.correctionReason,
        lifecycleState: revision.lifecycle.state,
      })),
    };
  }
}
