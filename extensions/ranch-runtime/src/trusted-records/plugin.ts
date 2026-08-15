import path from "node:path";
import type { OpenClawPluginApi } from "openclaw/plugin-sdk/plugin-entry";
import { isTruthyEnvValue } from "openclaw/plugin-sdk/runtime-env";
import { createTrustedRecordsDevelopmentHttpHandler } from "./http-route.js";
import {
  createTrustedRecordDevelopmentRuntime,
  type TrustedRecordDevelopmentRuntime,
} from "./runtime.development.js";

export type TrustedRecordsDevelopmentRegistration = {
  enabled: boolean;
};

export function registerTrustedRecordsDevelopment(
  api: OpenClawPluginApi,
): TrustedRecordsDevelopmentRegistration {
  const enabled = isTruthyEnvValue(process.env.OPENCLAW_TRUSTED_RECORDS_DEV);

  if (!enabled) {
    return { enabled: false };
  }

  const actorId = process.env.OPENCLAW_TRUSTED_RECORDS_DEV_ACTOR_ID?.trim() || "development-owner";

  let runtime: TrustedRecordDevelopmentRuntime | undefined;

  api.registerService({
    id: "ranch-runtime-trusted-records",

    start(ctx) {
      if (runtime) {
        return;
      }

      runtime = createTrustedRecordDevelopmentRuntime({
        dataDir: path.join(ctx.stateDir, "trusted-records"),
      });

      ctx.logger.info("Ranch Runtime Trusted Records development runtime started");
    },

    stop(ctx) {
      if (!runtime) {
        return;
      }

      const activeRuntime = runtime;
      runtime = undefined;

      activeRuntime.close();

      ctx.logger.info("Ranch Runtime Trusted Records development runtime stopped");
    },
  });

  api.registerHttpRoute({
    path: "/api/dev/trusted-records/",
    auth: "gateway",
    match: "prefix",

    handler: createTrustedRecordsDevelopmentHttpHandler(() =>
      runtime
        ? {
            runtime,
            actorId,
          }
        : undefined,
    ),
  });

  return { enabled: true };
}
