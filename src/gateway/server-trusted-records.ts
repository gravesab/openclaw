import path from "node:path";
import { resolveStateDir } from "../config/paths.js";
import { isTruthyEnvValue } from "../infra/env.js";

export type GatewayTrustedRecordDevelopmentOptions = {
  dataDir: string;
};

export function resolveGatewayTrustedRecordDevelopmentOptions(
  env: NodeJS.ProcessEnv = process.env,
): GatewayTrustedRecordDevelopmentOptions | undefined {
  if (!isTruthyEnvValue(env.OPENCLAW_TRUSTED_RECORDS_DEV)) {
    return undefined;
  }
  return {
    dataDir: path.join(resolveStateDir(env), "trusted-records"),
  };
}
