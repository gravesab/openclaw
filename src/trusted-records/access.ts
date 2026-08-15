import { TrustedRecordAccessDeniedError } from "./errors.js";
import type { TrustedRecordStore } from "./store.js";
import type { TrustedRecord, TrustedRecordCorrection } from "./types.js";

export type TrustedRecordAction = "read" | "correct" | "archive" | "reference" | "delete_preview";

export type TrustedRecordActor = {
  id: string;
  roles: ReadonlySet<string>;
};

export type TrustedRecordAccessPolicy = {
  id: string;
  ownerId: string;
  readActorIds: ReadonlySet<string>;
  writeActorIds: ReadonlySet<string>;
};

export type TrustedRecordAuditEvent = {
  occurredAt: string;
  actorId: string;
  action: TrustedRecordAction;
  recordId: string;
  decision: "allowed" | "denied";
  policyId: string;
  reason: "policy_grant" | "policy_denial";
};

export type TrustedRecordAuditSink = {
  append: (event: TrustedRecordAuditEvent) => void;
};

export type TrustedRecordPolicySource = {
  get: (policyId: string) => TrustedRecordAccessPolicy;
};

export class InMemoryTrustedRecordAuditSink implements TrustedRecordAuditSink {
  readonly #events: TrustedRecordAuditEvent[] = [];

  append(event: TrustedRecordAuditEvent): void {
    this.#events.push(structuredClone(event));
  }

  events(): TrustedRecordAuditEvent[] {
    return structuredClone(this.#events);
  }
}

export class TrustedRecordPolicyRegistry {
  readonly #policies = new Map<string, TrustedRecordAccessPolicy>();

  register(policy: TrustedRecordAccessPolicy): void {
    if (this.#policies.has(policy.id)) {
      throw new Error(`policy already exists: ${policy.id}`);
    }
    this.#policies.set(policy.id, {
      ...policy,
      readActorIds: new Set(policy.readActorIds),
      writeActorIds: new Set(policy.writeActorIds),
    });
  }

  get(policyId: string): TrustedRecordAccessPolicy {
    const policy = this.#policies.get(policyId);
    if (!policy) {
      throw new Error(`policy not found: ${policyId}`);
    }
    return {
      ...policy,
      readActorIds: new Set(policy.readActorIds),
      writeActorIds: new Set(policy.writeActorIds),
    };
  }
}

function policyPermits(
  policy: TrustedRecordAccessPolicy,
  actor: TrustedRecordActor,
  action: TrustedRecordAction,
): boolean {
  if (actor.id === policy.ownerId || actor.roles.has("system_admin")) {
    return true;
  }
  if (action === "read") {
    return policy.readActorIds.has(actor.id) || policy.writeActorIds.has(actor.id);
  }
  return policy.writeActorIds.has(actor.id);
}

export class SecureTrustedRecordService {
  constructor(
    readonly store: TrustedRecordStore,
    readonly policies: TrustedRecordPolicySource,
    readonly auditSink: TrustedRecordAuditSink,
    readonly now: () => Date = () => new Date(),
  ) {}

  authorize(actor: TrustedRecordActor, action: TrustedRecordAction, record: TrustedRecord): void {
    const policy = this.policies.get(record.security.accessPolicyId);
    const allowed = policyPermits(policy, actor, action);
    this.auditSink.append({
      occurredAt: this.now().toISOString(),
      actorId: actor.id,
      action,
      recordId: record.id,
      decision: allowed ? "allowed" : "denied",
      policyId: policy.id,
      reason: allowed ? "policy_grant" : "policy_denial",
    });
    if (!allowed) {
      throw new TrustedRecordAccessDeniedError();
    }
  }

  read(actor: TrustedRecordActor, recordId: string): TrustedRecord {
    const record = this.store.get(recordId);
    this.authorize(actor, "read", record);
    return record;
  }

  correct(
    actor: TrustedRecordActor,
    recordId: string,
    correction: TrustedRecordCorrection,
  ): TrustedRecord {
    const record = this.store.get(recordId);
    this.authorize(actor, "correct", record);
    return this.store.correct(recordId, correction);
  }

  deletionPreview(
    actor: TrustedRecordActor,
    recordId: string,
  ): {
    recordId: string;
    recordType: string;
    title: string;
    currentRevisionId: string;
    visibleDependents: Array<Pick<TrustedRecord, "id" | "recordType" | "ownerDomain" | "title">>;
    restrictedDependentCount: number;
    deletionAllowed: boolean;
    requiredAction: "resolve_dependents" | "confirm_deletion";
  } {
    const record = this.store.get(recordId);
    this.authorize(actor, "delete_preview", record);
    const visibleDependents = [];
    let restrictedDependentCount = 0;
    for (const dependent of this.store.dependents(recordId)) {
      try {
        this.authorize(actor, "read", dependent);
      } catch (error) {
        if (!(error instanceof TrustedRecordAccessDeniedError)) {
          throw error;
        }
        restrictedDependentCount += 1;
        continue;
      }
      visibleDependents.push({
        id: dependent.id,
        recordType: dependent.recordType,
        ownerDomain: dependent.ownerDomain,
        title: dependent.title,
      });
    }
    const deletionAllowed = visibleDependents.length === 0 && restrictedDependentCount === 0;
    return {
      recordId,
      recordType: record.recordType,
      title: record.title,
      currentRevisionId: record.revisionId,
      visibleDependents,
      restrictedDependentCount,
      deletionAllowed,
      requiredAction: deletionAllowed ? "confirm_deletion" : "resolve_dependents",
    };
  }
}
