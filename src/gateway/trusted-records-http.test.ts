import { Readable } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import {
  TrustedRecordAccessDeniedError,
  TrustedRecordNotFoundError,
} from "../trusted-records/errors.js";
import type { TrustedRecordDevelopmentRuntime } from "../trusted-records/runtime.development.js";
import { handleTrustedRecordsDevelopmentHttpRequest } from "./trusted-records-http.js";

function request(params: { method: string; url: string; body?: unknown }) {
  const req = Readable.from(params.body === undefined ? [] : [JSON.stringify(params.body)]);
  return Object.assign(req, {
    method: params.method,
    url: params.url,
    headers: { host: "localhost" },
  }) as unknown as import("node:http").IncomingMessage;
}

function response() {
  let body = "";
  const headers = new Map<string, string>();
  const res = {
    statusCode: 0,
    setHeader(name: string, value: string) {
      headers.set(name.toLowerCase(), value);
    },
    end(value?: string) {
      body = value ?? "";
    },
  } as unknown as import("node:http").ServerResponse;
  return {
    res,
    result: () => ({
      status: res.statusCode,
      headers,
      body: body ? (JSON.parse(body) as unknown) : undefined,
    }),
  };
}

function runtimeWith(overrides: {
  read?: ReturnType<typeof vi.fn>;
  correct?: ReturnType<typeof vi.fn>;
  deletionPreview?: ReturnType<typeof vi.fn>;
}) {
  return {
    secureRecords: {
      read: overrides.read ?? vi.fn(),
      correct: overrides.correct ?? vi.fn(),
      deletionPreview: overrides.deletionPreview ?? vi.fn(),
    },
  } as unknown as TrustedRecordDevelopmentRuntime;
}

const auth = { mode: "token", token: "unused", allowTailscale: false } as const;

describe("trusted-record development HTTP boundary", () => {
  it("reads as the server-configured actor after gateway authorization", async () => {
    const read = vi.fn().mockReturnValue({ id: "record-1", title: "Roof inspection" });
    const output = response();

    const handled = await handleTrustedRecordsDevelopmentHttpRequest(
      request({ method: "GET", url: "/api/dev/trusted-records/record-1" }),
      output.res,
      {
        runtime: runtimeWith({ read }),
        actorId: "property-manager-dev",
        auth,
        authorize: async () => true,
      },
    );

    expect(handled).toBe(true);
    expect(read).toHaveBeenCalledWith(
      expect.objectContaining({ id: "property-manager-dev", roles: new Set() }),
      "record-1",
    );
    expect(output.result()).toMatchObject({
      status: 200,
      body: { ok: true, record: { id: "record-1", title: "Roof inspection" } },
    });
  });

  it("does not access records when gateway authorization fails", async () => {
    const read = vi.fn();
    const output = response();

    await handleTrustedRecordsDevelopmentHttpRequest(
      request({ method: "GET", url: "/api/dev/trusted-records/record-1" }),
      output.res,
      {
        runtime: runtimeWith({ read }),
        actorId: "property-manager-dev",
        auth,
        authorize: async () => false,
      },
    );

    expect(read).not.toHaveBeenCalled();
  });

  it("does not disclose whether a record was denied or absent", async () => {
    const deniedOutput = response();
    const missingOutput = response();
    const deniedRuntime = runtimeWith({
      read: vi.fn(() => {
        throw new TrustedRecordAccessDeniedError();
      }),
    });
    const missingRuntime = runtimeWith({
      read: vi.fn(() => {
        throw new TrustedRecordNotFoundError();
      }),
    });

    await handleTrustedRecordsDevelopmentHttpRequest(
      request({ method: "GET", url: "/api/dev/trusted-records/private-record" }),
      deniedOutput.res,
      { runtime: deniedRuntime, actorId: "actor", auth, authorize: async () => true },
    );
    await handleTrustedRecordsDevelopmentHttpRequest(
      request({ method: "GET", url: "/api/dev/trusted-records/missing-record" }),
      missingOutput.res,
      { runtime: missingRuntime, actorId: "actor", auth, authorize: async () => true },
    );

    expect(deniedOutput.result()).toEqual(missingOutput.result());
    expect(deniedOutput.result()).toMatchObject({
      status: 404,
      body: { ok: false, error: { type: "not_found", message: "record unavailable" } },
    });
  });

  it("accepts a correction with an immutable revision identifier", async () => {
    const correct = vi.fn().mockReturnValue({ id: "record-1", revisionId: "revision-2" });
    const output = response();
    const correction = {
      revisionId: "revision-2",
      correctionReason: "Confirmed invoice total",
      changes: { data: { amount: 1250 } },
    };

    await handleTrustedRecordsDevelopmentHttpRequest(
      request({
        method: "POST",
        url: "/api/dev/trusted-records/record-1/corrections",
        body: correction,
      }),
      output.res,
      {
        runtime: runtimeWith({ correct }),
        actorId: "property-manager-dev",
        auth,
        authorize: async () => true,
      },
    );

    expect(correct).toHaveBeenCalledWith(
      expect.objectContaining({ id: "property-manager-dev" }),
      "record-1",
      correction,
    );
    expect(output.result()).toMatchObject({ status: 200, body: { ok: true } });
  });
});
