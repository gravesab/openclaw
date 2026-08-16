export const TRUSTED_RECORD_SCHEMA_VERSION = "1.0" as const;

export const TRUSTED_RECORD_DOMAINS = [
  "property",
  "health",
  "finance",
  "energy",
  "system",
  "general",
] as const;

export const TRUSTED_RECORD_DATA_STATES = [
  "measured",
  "entered",
  "imported",
  "estimated",
  "not_collected",
  "not_connected",
  "processing",
  "stale",
  "error",
  "not_applicable",
] as const;

export const TRUSTED_RECORD_SOURCE_TYPES = [
  "user",
  "document",
  "import",
  "connector",
  "system",
  "ai",
] as const;

export const TRUSTED_RECORD_SENSITIVITIES = ["standard", "private", "restricted"] as const;

export const TRUSTED_RECORD_RELATIONSHIP_TYPES = [
  "concerns",
  "derived_from",
  "documents",
  "supports",
  "contradicts",
  "replaces",
  "related_to",
  "created_task",
] as const;

export type TrustedRecordDomain = (typeof TRUSTED_RECORD_DOMAINS)[number];
export type TrustedRecordDataState = (typeof TRUSTED_RECORD_DATA_STATES)[number];
export type TrustedRecordSourceType = (typeof TRUSTED_RECORD_SOURCE_TYPES)[number];
export type TrustedRecordSensitivity = (typeof TRUSTED_RECORD_SENSITIVITIES)[number];
export type TrustedRecordRelationshipType = (typeof TRUSTED_RECORD_RELATIONSHIP_TYPES)[number];

export type TrustedRecord = {
  schemaVersion: typeof TRUSTED_RECORD_SCHEMA_VERSION;
  id: string;
  revisionId: string;
  recordType: string;
  ownerDomain: TrustedRecordDomain;
  title: string;
  summary: string | null;
  occurredAt: string;
  createdAt: string;
  updatedAt: string;
  lifecycle: {
    state: string;
    reason: string | null;
  };
  dataState: {
    state: TrustedRecordDataState;
    observedAt: string | null;
    lastSuccessfulUpdateAt: string | null;
    freshnessExpiresAt: string | null;
    error: { code: string; message: string } | null;
  };
  source: {
    type: TrustedRecordSourceType;
    sourceId: string;
    capturedAt: string;
    originalRecordId: string | null;
    externalReference: string | null;
  };
  provenance: {
    inputRecordIds: string[];
    derivationType: string | null;
    derivationDescription: string | null;
    model: string | null;
    confidence: number | null;
  };
  security: {
    sensitivity: TrustedRecordSensitivity;
    ownerId: string;
    accessPolicyId: string;
  };
  version: {
    number: number;
    previousRevisionId: string | null;
    supersedesRecordId: string | null;
    correctionReason: string | null;
  };
  relationships: Array<{
    type: TrustedRecordRelationshipType;
    targetRecordId: string;
    createdAt: string;
    source: TrustedRecordSourceType;
  }>;
  data: Record<string, unknown>;
};

export type TrustedRecordCorrection = {
  revisionId: string;
  correctionReason: string;
  changes: Partial<
    Omit<TrustedRecord, "schemaVersion" | "id" | "revisionId" | "createdAt" | "version">
  >;
};
