import { describe, expect, it } from "vitest";
import { resolveGatewayTrustedRecordDevelopmentOptions } from "./server-trusted-records.js";

describe("resolveGatewayTrustedRecordDevelopmentOptions", () => {
  it("is disabled by default", () => {
    expect(resolveGatewayTrustedRecordDevelopmentOptions({})).toBeUndefined();
  });

  it("uses a dedicated directory beneath the configured state directory", () => {
    expect(
      resolveGatewayTrustedRecordDevelopmentOptions({
        OPENCLAW_TRUSTED_RECORDS_DEV: "1",
        OPENCLAW_STATE_DIR: "/tmp/openclaw-test-state",
      }),
    ).toEqual({ dataDir: "/tmp/openclaw-test-state/trusted-records" });
  });
});
