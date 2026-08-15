import type { IncomingMessage, ServerResponse } from "node:http";
import { ZodError } from "zod";
import {
  TrustedRecordAccessDeniedError,
  TrustedRecordConflictError,
  TrustedRecordNotFoundError,
} from "./errors.js";
import {
  createTrustedRecordActor,
  type TrustedRecordDevelopmentRuntime,
} from "./runtime.development.js";
import type { TrustedRecordCorrection } from "./types.js";

const ROUTE_PREFIX = "/api/dev/trusted-records/";
const MAX_BODY_BYTES = 256 * 1024;

type TrustedRecordsRuntimeAccess = {
  runtime: TrustedRecordDevelopmentRuntime;
  actorId: string;
};

type TrustedRecordsRuntimeAccessor = () => TrustedRecordsRuntimeAccess | undefined;

function sendJson(res: ServerResponse, statusCode: number, body: unknown): void {
  const payload = JSON.stringify(body);

  res.statusCode = statusCode;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.setHeader("content-length", Buffer.byteLength(payload));
  res.end(payload);
}

function sendMethodNotAllowed(res: ServerResponse, allow: string): void {
  res.setHeader("allow", allow);

  sendJson(res, 405, {
    ok: false,
    error: {
      type: "method_not_allowed",
      message: `method not allowed; use ${allow}`,
    },
  });
}

async function readJsonBody(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<unknown | undefined> {
  const chunks: Buffer[] = [];
  let totalBytes = 0;
  let tooLarge = false;

  try {
    for await (const chunk of req) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);

      totalBytes += buffer.length;

      if (totalBytes > MAX_BODY_BYTES) {
        tooLarge = true;
        continue;
      }

      if (!tooLarge) {
        chunks.push(buffer);
      }
    }
  } catch {
    sendJson(res, 400, {
      ok: false,
      error: {
        type: "invalid_request",
        message: "unable to read request body",
      },
    });

    return undefined;
  }

  if (tooLarge) {
    sendJson(res, 413, {
      ok: false,
      error: {
        type: "payload_too_large",
        message: "request body exceeds 256 KiB",
      },
    });

    return undefined;
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
  } catch {
    sendJson(res, 400, {
      ok: false,
      error: {
        type: "invalid_request",
        message: "request body must be valid JSON",
      },
    });

    return undefined;
  }
}

function parseRoute(pathname: string):
  | {
      recordId: string;
      operation: "read" | "correct" | "deletion-preview";
    }
  | undefined {
  if (!pathname.startsWith(ROUTE_PREFIX)) {
    return undefined;
  }

  const suffix = pathname.slice(ROUTE_PREFIX.length);

  const match = /^([^/]+)(?:\/(corrections|deletion-preview))?$/.exec(suffix);

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
  sendJson(res, 404, {
    ok: false,
    error: {
      type: "not_found",
      message: "record unavailable",
    },
  });
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
    sendJson(res, 409, {
      ok: false,
      error: {
        type: "conflict",
        message: error.message,
      },
    });

    return;
  }

  if (error instanceof ZodError) {
    sendJson(res, 400, {
      ok: false,
      error: {
        type: "invalid_record",
        message: "record correction is invalid",
      },
    });

    return;
  }

  throw error;
}

export function createTrustedRecordsDevelopmentHttpHandler(
  getRuntime: TrustedRecordsRuntimeAccessor,
) {
  return async (req: IncomingMessage, res: ServerResponse): Promise<boolean> => {
    let pathname: string;

    try {
      pathname = new URL(req.url ?? "/", "http://localhost").pathname;
    } catch {
      return false;
    }

    const route = parseRoute(pathname);

    if (!route) {
      sendJson(res, 404, {
        ok: false,
        error: {
          type: "not_found",
          message: "route unavailable",
        },
      });

      return true;
    }

    if (route.operation === "read" && req.method !== "GET") {
      sendMethodNotAllowed(res, "GET");
      return true;
    }

    if (route.operation !== "read" && req.method !== "POST") {
      sendMethodNotAllowed(res, "POST");
      return true;
    }

    const access = getRuntime();

    if (!access) {
      sendJson(res, 503, {
        ok: false,
        error: {
          type: "unavailable",
          message: "Trusted Records development runtime is unavailable",
        },
      });

      return true;
    }

    const actor = createTrustedRecordActor({
      id: access.actorId,
    });

    try {
      if (route.operation === "read") {
        sendJson(res, 200, {
          ok: true,
          record: access.runtime.secureRecords.read(actor, route.recordId),
        });

        return true;
      }

      if (route.operation === "deletion-preview") {
        sendJson(res, 200, {
          ok: true,
          preview: access.runtime.secureRecords.deletionPreview(actor, route.recordId),
        });

        return true;
      }

      const body = await readJsonBody(req, res);

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
        record: access.runtime.secureRecords.correct(actor, route.recordId, correction),
      });

      return true;
    } catch (error) {
      sendOperationError(res, error);
      return true;
    }
  };
}
