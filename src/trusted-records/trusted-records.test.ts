import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  InMemoryTrustedRecordAuditSink,
  SecureTrustedRecordService,
  TrustedRecordAccessDeniedError,
  TrustedRecordInboxService,
  TrustedRecordInspector,
  TrustedRecordPolicyRegistry,
  createSqliteTrustedRecordSecurityStore,
  createSqliteTrustedRecordStore,
  createTrustedRecordDevelopmentRuntime,
  parseTrustedRecord,
  type SqliteTrustedRecordStore,
  type TrustedRecord,
  type TrustedRecordActor,
} from "./index.js";

const NOW = new Date("2026-08-04T21:00:00.000Z");

function createRecord(params: {
  id: string;
  revisionId: string;
  recordType: string;
  ownerDomain: TrustedRecord["ownerDomain"];
  title: string;
  policyId: string;
  sensitivity?: TrustedRecord["security"]["sensitivity"];
  dataState?: TrustedRecord["dataState"]["state"];
  lifecycleState?: string;
  data?: Record<string, unknown>;
}): TrustedRecord {
  const timestamp = "2026-08-03T20:00:00.000Z";
  return parseTrustedRecord({
    schemaVersion: "1.0",
    id: params.id,
    revisionId: params.revisionId,
    recordType: params.recordType,
    ownerDomain: params.ownerDomain,
    title: params.title,
    summary: null,
    occurredAt: timestamp,
    createdAt: timestamp,
    updatedAt: timestamp,
    lifecycle: { state: params.lifecycleState ?? "active", reason: null },
    dataState: {
      state: params.dataState ?? "entered",
      observedAt: timestamp,
      lastSuccessfulUpdateAt: timestamp,
      freshnessExpiresAt: null,
      error: null,
    },
    source: {
      type: "user",
      sourceId: "usr_owner",
      capturedAt: timestamp,
      originalRecordId: null,
      externalReference: null,
    },
    provenance: {
      inputRecordIds: [],
      derivationType: null,
      derivationDescription: null,
      model: null,
      confidence: null,
    },
    security: {
      sensitivity: params.sensitivity ?? "standard",
      ownerId: "usr_owner",
      accessPolicyId: params.policyId,
    },
    version: {
      number: 1,
      previousRevisionId: null,
      supersedesRecordId: null,
      correctionReason: null,
    },
    relationships: [],
    data: params.data ?? {},
  });
}

describe("trusted record foundation", () => {
  let directory: string;
  let path: string;
  let store: SqliteTrustedRecordStore;
  const owner: TrustedRecordActor = { id: "usr_owner", roles: new Set() };
  const stranger: TrustedRecordActor = { id: "usr_stranger", roles: new Set() };

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), "openclaw-trusted-records-"));
    path = join(directory, "records.sqlite3");
    store = createSqliteTrustedRecordStore({ path, now: () => NOW });
  });

  afterEach(() => {
    store.close();
    rmSync(directory, { recursive: true, force: true });
  });

  it("rejects standard sensitivity for Finance records", () => {
    expect(() =>
      createRecord({
        id: "rec_FINANCE",
        revisionId: "rev_FINANCE",
        recordType: "finance.transaction",
        ownerDomain: "finance",
        title: "Private transaction",
        policyId: "policy_finance",
      }),
    ).toThrow("health and finance records must be private or restricted");
  });

  it("rejects a false zero when data is unavailable", () => {
    expect(() =>
      createRecord({
        id: "rec_ENERGY",
        revisionId: "rev_ENERGY",
        recordType: "energy.meter_status",
        ownerDomain: "energy",
        title: "Disconnected meter",
        policyId: "policy_energy",
        dataState: "not_connected",
        data: { reading: 0, unit: "kWh" },
      }),
    ).toThrow("reading must be null when data is unavailable");
  });

  it("persists immutable corrections across restart", () => {
    const record = createRecord({
      id: "rec_PROPERTY",
      revisionId: "rev_PROPERTY1",
      recordType: "property.maintenance_note",
      ownerDomain: "property",
      title: "Fence inspection",
      policyId: "policy_property",
      data: { loosePostCount: 2 },
    });
    store.create(record);
    store.correct(record.id, {
      revisionId: "rev_PROPERTY2",
      correctionReason: "Owner confirmed three posts",
      changes: { data: { loosePostCount: 3 } },
    });
    store.close();
    store = createSqliteTrustedRecordStore({ path, now: () => NOW });
    expect(store.get(record.id).version.number).toBe(2);
    expect(store.history(record.id)).toHaveLength(2);
    expect(store.getRevision("rev_PROPERTY1").data.loosePostCount).toBe(2);
  });

  it("denies private reads without disclosing record metadata and audits the decision", () => {
    const finance = createRecord({
      id: "rec_FINANCEPRIVATE",
      revisionId: "rev_FINANCEPRIVATE",
      recordType: "finance.transaction",
      ownerDomain: "finance",
      title: "Private transaction",
      policyId: "policy_finance",
      sensitivity: "private",
    });
    store.create(finance);
    const policies = new TrustedRecordPolicyRegistry();
    policies.register({
      id: "policy_finance",
      ownerId: owner.id,
      readActorIds: new Set(),
      writeActorIds: new Set(),
    });
    const audit = new InMemoryTrustedRecordAuditSink();
    const secure = new SecureTrustedRecordService(store, policies, audit, () => NOW);
    expect(() => secure.read(stranger, finance.id)).toThrow(TrustedRecordAccessDeniedError);
    expect(() => secure.read(stranger, finance.id)).toThrow("record is unavailable");
    expect(audit.events().at(-1)).toMatchObject({
      actorId: stranger.id,
      action: "read",
      decision: "denied",
    });
  });

  it("persists policies and append-only access decisions across restart", () => {
    const finance = createRecord({
      id: "rec_FINANCEAUDITED",
      revisionId: "rev_FINANCEAUDITED",
      recordType: "finance.transaction",
      ownerDomain: "finance",
      title: "Audited transaction",
      policyId: "policy_finance_persistent",
      sensitivity: "private",
    });
    store.create(finance);
    const securityPath = join(directory, "trusted-record-security.sqlite3");
    let security = createSqliteTrustedRecordSecurityStore({ path: securityPath });
    security.register({
      id: "policy_finance_persistent",
      ownerId: owner.id,
      readActorIds: new Set(),
      writeActorIds: new Set(),
    });
    let secure = new SecureTrustedRecordService(store, security, security, () => NOW);
    expect(secure.read(owner, finance.id).id).toBe(finance.id);
    expect(() => secure.read(stranger, finance.id)).toThrow(TrustedRecordAccessDeniedError);
    security.close();

    security = createSqliteTrustedRecordSecurityStore({ path: securityPath });
    secure = new SecureTrustedRecordService(store, security, security, () => NOW);
    expect(security.get("policy_finance_persistent").ownerId).toBe(owner.id);
    expect(security.events(finance.id)).toMatchObject([
      { actorId: owner.id, decision: "allowed", action: "read" },
      { actorId: stranger.id, decision: "denied", action: "read" },
    ]);
    expect(secure.read(owner, finance.id).id).toBe(finance.id);
    expect(security.events(finance.id)).toHaveLength(3);
    security.close();
  });

  it("resolves Inbox capture atomically and exposes history through the inspector", () => {
    const capture = createRecord({
      id: "rec_CAPTURE",
      revisionId: "rev_CAPTURE1",
      recordType: "general.capture",
      ownerDomain: "general",
      title: "Fence note",
      policyId: "policy_general",
      lifecycleState: "captured",
      data: { classificationStatus: "needs_confirmation" },
    });
    const property = createRecord({
      id: "rec_RESOLVED",
      revisionId: "rev_RESOLVED1",
      recordType: "property.maintenance_note",
      ownerDomain: "property",
      title: "Fence inspection",
      policyId: "policy_property",
      data: { loosePostCount: 2 },
    });
    store.create(capture);
    const policies = new TrustedRecordPolicyRegistry();
    for (const policyId of ["policy_general", "policy_property"]) {
      policies.register({
        id: policyId,
        ownerId: owner.id,
        readActorIds: new Set(),
        writeActorIds: new Set(),
      });
    }
    const audit = new InMemoryTrustedRecordAuditSink();
    const secure = new SecureTrustedRecordService(store, policies, audit, () => NOW);
    const inbox = new TrustedRecordInboxService(secure);
    const result = inbox.resolve({
      actor: owner,
      captureId: capture.id,
      resolvedRecord: property,
      captureRevisionId: "rev_CAPTURE2",
      reason: "Owner confirmed Property classification",
    });
    expect(result.capture.lifecycle.state).toBe("resolved");
    expect(result.resolvedRecord.source.originalRecordId).toBe(capture.id);
    expect(result.resolvedRecord.relationships).toContainEqual(
      expect.objectContaining({ type: "derived_from", targetRecordId: capture.id }),
    );
    const inspector = new TrustedRecordInspector(secure);
    expect(inspector.inspect(owner, capture.id).history).toHaveLength(2);
  });

  it("blocks deletion confirmation while visible dependents remain", () => {
    const property = createRecord({
      id: "rec_PROPERTYDEPENDENT",
      revisionId: "rev_PROPERTYDEPENDENT1",
      recordType: "property.maintenance_note",
      ownerDomain: "property",
      title: "Pump inspection",
      policyId: "policy_property",
    });
    const energy = createRecord({
      id: "rec_ENERGYTARGET",
      revisionId: "rev_ENERGYTARGET1",
      recordType: "energy.meter_status",
      ownerDomain: "energy",
      title: "Pump meter",
      policyId: "policy_energy",
      dataState: "not_connected",
      data: { reading: null },
    });
    store.create(property);
    store.create(energy);
    store.addReference({
      recordId: property.id,
      targetRecordId: energy.id,
      revisionId: "rev_PROPERTYDEPENDENT2",
      relationshipType: "related_to",
      source: "user",
      reason: "Link maintenance to meter",
    });
    const policies = new TrustedRecordPolicyRegistry();
    for (const policyId of ["policy_property", "policy_energy"]) {
      policies.register({
        id: policyId,
        ownerId: owner.id,
        readActorIds: new Set(),
        writeActorIds: new Set(),
      });
    }
    const secure = new SecureTrustedRecordService(
      store,
      policies,
      new InMemoryTrustedRecordAuditSink(),
      () => NOW,
    );
    expect(secure.deletionPreview(owner, energy.id)).toMatchObject({
      deletionAllowed: false,
      requiredAction: "resolve_dependents",
      visibleDependents: [{ id: property.id }],
    });
  });

  it("creates an isolated development runtime without application activation", () => {
    const runtime = createTrustedRecordDevelopmentRuntime({
      dataDir: join(directory, "development-runtime"),
      now: () => NOW,
    });
    runtime.security.register({
      id: "policy_development",
      ownerId: owner.id,
      readActorIds: new Set(),
      writeActorIds: new Set(),
    });
    const record = createRecord({
      id: "rec_DEVELOPMENT",
      revisionId: "rev_DEVELOPMENT",
      recordType: "property.maintenance_note",
      ownerDomain: "property",
      title: "Development-only record",
      policyId: "policy_development",
    });
    runtime.records.create(record);
    expect(runtime.secureRecords.read(owner, record.id).id).toBe(record.id);
    expect(runtime.security.events(record.id)).toHaveLength(1);
    runtime.close();
  });
});
