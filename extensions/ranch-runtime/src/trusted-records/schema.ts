import { z } from "zod";
import {
  TRUSTED_RECORD_DATA_STATES,
  TRUSTED_RECORD_DOMAINS,
  TRUSTED_RECORD_RELATIONSHIP_TYPES,
  TRUSTED_RECORD_SCHEMA_VERSION,
  TRUSTED_RECORD_SENSITIVITIES,
  TRUSTED_RECORD_SOURCE_TYPES,
  type TrustedRecord,
} from "./types.js";

const RecordIdSchema = z.string().regex(/^rec_[A-Za-z0-9]+$/);
const RevisionIdSchema = z.string().regex(/^rev_[A-Za-z0-9]+$/);
const TimestampSchema = z.iso.datetime({ offset: true });

const DataStateSchema = z
  .object({
    state: z.enum(TRUSTED_RECORD_DATA_STATES),
    observedAt: TimestampSchema.nullable(),
    lastSuccessfulUpdateAt: TimestampSchema.nullable(),
    freshnessExpiresAt: TimestampSchema.nullable(),
    error: z
      .object({ code: z.string().min(1), message: z.string().min(1) })
      .strict()
      .nullable(),
  })
  .strict();

const SourceSchema = z
  .object({
    type: z.enum(TRUSTED_RECORD_SOURCE_TYPES),
    sourceId: z.string().min(1),
    capturedAt: TimestampSchema,
    originalRecordId: RecordIdSchema.nullable(),
    externalReference: z.string().nullable(),
  })
  .strict();

const ProvenanceSchema = z
  .object({
    inputRecordIds: z.array(RecordIdSchema),
    derivationType: z.string().nullable(),
    derivationDescription: z.string().nullable(),
    model: z.string().nullable(),
    confidence: z.number().min(0).max(1).nullable(),
  })
  .strict();

export const TrustedRecordSchema = z
  .object({
    schemaVersion: z.literal(TRUSTED_RECORD_SCHEMA_VERSION),
    id: RecordIdSchema,
    revisionId: RevisionIdSchema,
    recordType: z.string().regex(/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/),
    ownerDomain: z.enum(TRUSTED_RECORD_DOMAINS),
    title: z.string().min(1).max(240),
    summary: z.string().max(2000).nullable(),
    occurredAt: TimestampSchema,
    createdAt: TimestampSchema,
    updatedAt: TimestampSchema,
    lifecycle: z.object({ state: z.string().min(1), reason: z.string().nullable() }).strict(),
    dataState: DataStateSchema,
    source: SourceSchema,
    provenance: ProvenanceSchema,
    security: z
      .object({
        sensitivity: z.enum(TRUSTED_RECORD_SENSITIVITIES),
        ownerId: z.string().min(1),
        accessPolicyId: z.string().min(1),
      })
      .strict(),
    version: z
      .object({
        number: z.number().int().min(1),
        previousRevisionId: RevisionIdSchema.nullable(),
        supersedesRecordId: RecordIdSchema.nullable(),
        correctionReason: z.string().nullable(),
      })
      .strict(),
    relationships: z.array(
      z
        .object({
          type: z.enum(TRUSTED_RECORD_RELATIONSHIP_TYPES),
          targetRecordId: RecordIdSchema,
          createdAt: TimestampSchema,
          source: z.enum(TRUSTED_RECORD_SOURCE_TYPES),
        })
        .strict(),
    ),
    data: z.record(z.string(), z.unknown()),
  })
  .strict()
  .superRefine((record, context) => {
    if (!record.recordType.startsWith(`${record.ownerDomain}.`)) {
      context.addIssue({
        code: "custom",
        path: ["recordType"],
        message: "recordType namespace must match ownerDomain",
      });
    }
    if (
      (record.ownerDomain === "health" || record.ownerDomain === "finance") &&
      record.security.sensitivity === "standard"
    ) {
      context.addIssue({
        code: "custom",
        path: ["security", "sensitivity"],
        message: "health and finance records must be private or restricted",
      });
    }
    if (record.provenance.inputRecordIds.includes(record.id)) {
      context.addIssue({
        code: "custom",
        path: ["provenance", "inputRecordIds"],
        message: "a record cannot derive from itself",
      });
    }
    if (record.source.type === "ai") {
      if (record.provenance.inputRecordIds.length === 0) {
        context.addIssue({
          code: "custom",
          path: ["provenance", "inputRecordIds"],
          message: "AI-derived records require input records",
        });
      }
      if (!record.provenance.derivationDescription?.trim()) {
        context.addIssue({
          code: "custom",
          path: ["provenance", "derivationDescription"],
          message: "AI-derived records require a derivation description",
        });
      }
      if (!record.provenance.model?.trim()) {
        context.addIssue({
          code: "custom",
          path: ["provenance", "model"],
          message: "AI-derived records require a model identifier",
        });
      }
    }
    if (record.dataState.state === "estimated") {
      if (record.provenance.inputRecordIds.length === 0) {
        context.addIssue({
          code: "custom",
          path: ["provenance", "inputRecordIds"],
          message: "estimated records require input records",
        });
      }
      if (!record.provenance.derivationDescription?.trim()) {
        context.addIssue({
          code: "custom",
          path: ["provenance", "derivationDescription"],
          message: "estimated records require a derivation description",
        });
      }
    }
    if (record.dataState.state === "stale" && !record.dataState.lastSuccessfulUpdateAt) {
      context.addIssue({
        code: "custom",
        path: ["dataState", "lastSuccessfulUpdateAt"],
        message: "stale records require a last successful update",
      });
    }
    if (record.dataState.state === "error" && !record.dataState.error) {
      context.addIssue({
        code: "custom",
        path: ["dataState", "error"],
        message: "error records require error details",
      });
    }
    if (record.dataState.state !== "error" && record.dataState.error) {
      context.addIssue({
        code: "custom",
        path: ["dataState", "error"],
        message: "error details are only valid for error records",
      });
    }
    if (Date.parse(record.updatedAt) < Date.parse(record.createdAt)) {
      context.addIssue({
        code: "custom",
        path: ["updatedAt"],
        message: "updatedAt cannot be earlier than createdAt",
      });
    }
    if (record.version.number > 1) {
      if (!record.version.previousRevisionId) {
        context.addIssue({
          code: "custom",
          path: ["version", "previousRevisionId"],
          message: "corrected records require a previous revision",
        });
      }
      if (!record.version.correctionReason?.trim()) {
        context.addIssue({
          code: "custom",
          path: ["version", "correctionReason"],
          message: "corrected records require a correction reason",
        });
      }
    }
    for (const [index, relationship] of record.relationships.entries()) {
      if (relationship.targetRecordId === record.id) {
        context.addIssue({
          code: "custom",
          path: ["relationships", index, "targetRecordId"],
          message: "self-referential relationships are not permitted",
        });
      }
    }
    const unavailableStates = new Set([
      "not_collected",
      "not_connected",
      "processing",
      "error",
      "not_applicable",
    ]);
    if (unavailableStates.has(record.dataState.state)) {
      for (const field of ["value", "reading", "amount"] as const) {
        if (record.data[field] != null) {
          context.addIssue({
            code: "custom",
            path: ["data", field],
            message: `${field} must be null when data is unavailable`,
          });
        }
      }
    }
  });

export function parseTrustedRecord(value: unknown): TrustedRecord {
  return TrustedRecordSchema.parse(value) as TrustedRecord;
}
