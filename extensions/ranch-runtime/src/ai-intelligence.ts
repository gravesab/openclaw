import { spawn } from "node:child_process";
import path from "node:path";
import {
  ErrorCodes,
  errorShape,
  type GatewayRequestHandlerOptions,
} from "openclaw/plugin-sdk/gateway-runtime";
import { isRecord } from "openclaw/plugin-sdk/string-coerce-runtime";

const MAX_OUTPUT_BYTES = 1024 * 1024;

const ATTEMPT_STATUSES = new Set([
  "success",
  "timeout",
  "unavailable",
  "invalid-response",
  "provider-error",
]);

type AiExecuteParams = {
  componentId: string;
  prompt: string;
  requestId?: string;
  systemPrompt?: string;
  timeoutSeconds?: number;
};

type AiExecutionAttempt = {
  providerName: string;
  modelId: string;
  status: "success" | "timeout" | "unavailable" | "invalid-response" | "provider-error";
  startedAt: string;
  finishedAt: string;
  durationMs: number;
  errorType: string | null;
  errorMessage: string | null;
};

type AiExecuteResult = {
  requestId: string;
  componentId: string;
  status: "success" | "failed";
  content: string | null;
  selectedModelId: string | null;
  attempts: AiExecutionAttempt[];
};

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isStringOrNull(value: unknown): value is string | null {
  return typeof value === "string" || value === null;
}

function parseAiExecuteParams(value: unknown): AiExecuteParams | undefined {
  if (!isRecord(value)) {
    return undefined;
  }

  const allowedKeys = new Set([
    "componentId",
    "prompt",
    "requestId",
    "systemPrompt",
    "timeoutSeconds",
  ]);

  if (Object.keys(value).some((key) => !allowedKeys.has(key))) {
    return undefined;
  }

  if (!isNonEmptyString(value.componentId) || !isNonEmptyString(value.prompt)) {
    return undefined;
  }

  if (value.requestId !== undefined && !isNonEmptyString(value.requestId)) {
    return undefined;
  }

  if (value.systemPrompt !== undefined && !isNonEmptyString(value.systemPrompt)) {
    return undefined;
  }

  if (
    value.timeoutSeconds !== undefined &&
    (typeof value.timeoutSeconds !== "number" ||
      !Number.isFinite(value.timeoutSeconds) ||
      value.timeoutSeconds < 0.1 ||
      value.timeoutSeconds > 300)
  ) {
    return undefined;
  }

  return {
    componentId: value.componentId,
    prompt: value.prompt,
    ...(value.requestId !== undefined ? { requestId: value.requestId } : {}),
    ...(value.systemPrompt !== undefined ? { systemPrompt: value.systemPrompt } : {}),
    ...(value.timeoutSeconds !== undefined ? { timeoutSeconds: value.timeoutSeconds } : {}),
  };
}

function isAiExecutionAttempt(value: unknown): value is AiExecutionAttempt {
  if (!isRecord(value)) {
    return false;
  }

  return (
    isNonEmptyString(value.providerName) &&
    isNonEmptyString(value.modelId) &&
    typeof value.status === "string" &&
    ATTEMPT_STATUSES.has(value.status) &&
    isNonEmptyString(value.startedAt) &&
    isNonEmptyString(value.finishedAt) &&
    Number.isInteger(value.durationMs) &&
    (value.durationMs as number) >= 0 &&
    isStringOrNull(value.errorType) &&
    isStringOrNull(value.errorMessage)
  );
}

function isAiExecuteResult(value: unknown): value is AiExecuteResult {
  if (!isRecord(value)) {
    return false;
  }

  return (
    isNonEmptyString(value.requestId) &&
    isNonEmptyString(value.componentId) &&
    (value.status === "success" || value.status === "failed") &&
    isStringOrNull(value.content) &&
    isStringOrNull(value.selectedModelId) &&
    Array.isArray(value.attempts) &&
    value.attempts.length > 0 &&
    value.attempts.every(isAiExecutionAttempt)
  );
}

function resolveRuntimePaths(env: NodeJS.ProcessEnv = process.env) {
  const root = path.resolve(env.OPENCLAW_AI_INTELLIGENCE_ROOT ?? process.cwd());

  return {
    root,
    python:
      env.OPENCLAW_AI_INTELLIGENCE_PYTHON ??
      path.join(root, "tools", "ai_intelligence", ".venv", "bin", "python"),
    bridge:
      env.OPENCLAW_AI_INTELLIGENCE_BRIDGE ??
      path.join(root, "tools", "ai_intelligence", "gateway_bridge.py"),
  };
}

function isAiIntelligenceEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.OPENCLAW_AI_INTELLIGENCE_GATEWAY_ENABLED === "1";
}

async function executeAiIntelligence(params: AiExecuteParams): Promise<AiExecuteResult> {
  const runtime = resolveRuntimePaths();

  const processTimeoutMs = Math.ceil((params.timeoutSeconds ?? 60) * 1000) + 5000;

  return await new Promise<AiExecuteResult>((resolve, reject) => {
    const child = spawn(runtime.python, [runtime.bridge], {
      cwd: runtime.root,
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];

    let outputBytes = 0;
    let settled = false;

    const fail = (error: Error) => {
      if (settled) {
        return;
      }

      settled = true;
      clearTimeout(timer);
      reject(error);
    };

    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      fail(new Error(`AI Intelligence execution timed out after ${processTimeoutMs}ms`));
    }, processTimeoutMs);

    timer.unref?.();

    const collect = (target: Buffer[], chunk: Buffer) => {
      outputBytes += chunk.length;

      if (outputBytes > MAX_OUTPUT_BYTES) {
        child.kill("SIGKILL");
        fail(new Error("AI Intelligence execution exceeded the output limit"));
        return;
      }

      target.push(chunk);
    };

    child.stdout.on("data", (chunk: Buffer) => collect(stdout, chunk));
    child.stderr.on("data", (chunk: Buffer) => collect(stderr, chunk));
    child.on("error", fail);

    child.on("close", (code) => {
      if (settled) {
        return;
      }

      clearTimeout(timer);

      if (code !== 0) {
        fail(
          new Error(
            Buffer.concat(stderr).toString("utf8").trim() ||
              `AI Intelligence bridge exited with code ${code}`,
          ),
        );
        return;
      }

      try {
        const result = JSON.parse(Buffer.concat(stdout).toString("utf8")) as unknown;

        if (!isAiExecuteResult(result)) {
          fail(new Error("AI Intelligence bridge returned an invalid result"));
          return;
        }

        settled = true;
        resolve(result);
      } catch (error) {
        fail(new Error(`Invalid AI Intelligence bridge response: ${String(error)}`));
      }
    });

    child.stdin.end(JSON.stringify(params));
  });
}

export async function handleAiExecute({
  params,
  respond,
  context,
}: GatewayRequestHandlerOptions): Promise<void> {
  if (!isAiIntelligenceEnabled()) {
    respond(
      false,
      undefined,
      errorShape(ErrorCodes.UNAVAILABLE, "AI Intelligence gateway execution is disabled"),
    );
    return;
  }

  const parsed = parseAiExecuteParams(params);

  if (!parsed) {
    respond(false, undefined, errorShape(ErrorCodes.INVALID_REQUEST, "invalid ai.execute params"));
    return;
  }

  try {
    const result = await executeAiIntelligence(parsed);
    respond(true, result);
  } catch (error) {
    context.logGateway.warn(`AI Intelligence gateway execution failed: ${String(error)}`);

    respond(
      false,
      undefined,
      errorShape(ErrorCodes.UNAVAILABLE, "AI Intelligence execution failed"),
    );
  }
}
