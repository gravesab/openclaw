import type { IncomingMessage, ServerResponse } from "node:http";
import { ZodError } from "zod";
import {
  TrustedRecordAccessDeniedError,
  TrustedRecordConflictError,
  TrustedRecordNotFoundError,
  createTrustedRecordActor,
  type TrustedRecordCorrection,
  type TrustedRecordDevelopmentRuntime,
} from "../trusted-records/index.js";
import type { AuthRateLimiter } from "./auth-rate-limit.js";
import type { ResolvedGatewayAuth } from "./auth.js";
import { readJsonBodyOrError, sendJson, sendMethodNotAllowed } from "./http-common.js";
import { authorizeGatewayHttpRequestOrReply } from "./http-utils.js";

const ROUTE_PREFIX = "/api/dev/trusted-records/";
const MAX_BODY_BYTES = 256 * 1024;

export function isTrustedRecordsDevelopmentPath(pathname: string): boolean {
  return pathname.startsWith(ROUTE_PREFIX);
}

function parseRoute(
  pathname: string,
): { recordId: string; operation: "read" | "correct" | "deletion-preview" } | undefined {
  if (!isTrustedRecordsDevelopmentPath(pathname)) {
    return undefined;
  }
  const suffix = pathname.slice(ROUTE_PREFIX.length);
  const match = suffix.match(/^([^/]+)(?:\/(corrections|deletion-preview))?$/);
  if (!match?.[1]) {
    return undefined;
  }
  let recordId: string;
  try {
    recordId = decodeURIComponent(match[1]);
  } catch {
    return undefined;
  }
  if (!recordId.trim() || recordId.includes("/")) {
    return undefined;
  }
  return {
    recordId,
    operation:
      match[2] === "corrections"
        ? "correct"
        : match[2] === "deletion-preview"
          ? "deletion-preview"
          : "read",
  };
}

function parseCorrection(value: unknown): TrustedRecordCorrection | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  const candidate = value as Record<string, unknown>;
  if (
    typeof candidate.revisionId !== "string" ||
    !candidate.revisionId.trim() ||
    typeof candidate.correctionReason !== "string" ||
    !candidate.correctionReason.trim() ||
    !candidate.changes ||
    typeof candidate.changes !== "object" ||
    Array.isArray(candidate.changes)
  ) {
    return undefined;
  }
  return candidate as TrustedRecordCorrection;
}

function sendRecordUnavailable(res: ServerResponse): void {
  sendJson(res, 404, { ok: false, error: { type: "not_found", message: "record unavailable" } });
}

function sendOperationError(res: ServerResponse, error: unknown): void {
  if (
    error instanceof TrustedRecordNotFoundError ||
    error instanceof TrustedRecordAccessDeniedError
  ) {
    sendRecordUnavailable(res);
    return;
  }
  if (error instanceof TrustedRecordConflictError) {
    sendJson(res, 409, { ok: false, error: { type: "conflict", message: error.message } });
    return;
  }
  if (error instanceof ZodError) {
    sendJson(res, 400, {
      ok: false,
      error: { type: "invalid_record", message: "record correction is invalid" },
    });
    return;
  }
  throw error;
}

export async function handleTrustedRecordsDevelopmentHttpRequest(
  req: IncomingMessage,
  res: ServerResponse,
  opts: {
    runtime: TrustedRecordDevelopmentRuntime;
    actorId: string;
    auth: ResolvedGatewayAuth;
    trustedProxies?: string[];
    allowRealIpFallback?: boolean;
    rateLimiter?: AuthRateLimiter;
    authorize?: () => Promise<boolean>;
  },
): Promise<boolean> {
  let pathname: string;
  try {
    pathname = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`).pathname;
  } catch {
    return false;
  }
  if (!isTrustedRecordsDevelopmentPath(pathname)) {
    return false;
  }
  const route = parseRoute(pathname);
  if (!route) {
    sendJson(res, 404, { ok: false, error: { type: "not_found", message: "route unavailable" } });
    return true;
  }

  const authorized = opts.authorize
    ? await opts.authorize()
    : Boolean(
        await authorizeGatewayHttpRequestOrReply({
          req,
          res,
          auth: opts.auth,
          trustedProxies: opts.trustedProxies,
          allowRealIpFallback: opts.allowRealIpFallback,
          rateLimiter: opts.rateLimiter,
        }),
      );
  if (!authorized) {
    return true;
  }

  const actor = createTrustedRecordActor({ id: opts.actorId });
  try {
    if (route.operation === "read") {
      if (req.method !== "GET") {
        sendMethodNotAllowed(res, "GET");
        return true;
      }
      sendJson(res, 200, {
        ok: true,
        record: opts.runtime.secureRecords.read(actor, route.recordId),
      });
      return true;
    }

    if (req.method !== "POST") {
      sendMethodNotAllowed(res, "POST");
      return true;
    }
    if (route.operation === "deletion-preview") {
      sendJson(res, 200, {
        ok: true,
        preview: opts.runtime.secureRecords.deletionPreview(actor, route.recordId),
      });
      return true;
    }

    const body = await readJsonBodyOrError(req, res, MAX_BODY_BYTES);
    if (body === undefined) {
      return true;
    }
    const correction = parseCorrection(body);
    if (!correction) {
      sendJson(res, 400, {
        ok: false,
        error: {
          type: "invalid_request",
          message: "revisionId, correctionReason, and changes are required",
        },
      });
      return true;
    }
    sendJson(res, 200, {
      ok: true,
      record: opts.runtime.secureRecords.correct(actor, route.recordId, correction),
    });
    return true;
  } catch (error) {
    sendOperationError(res, error);
    return true;
  }
}
