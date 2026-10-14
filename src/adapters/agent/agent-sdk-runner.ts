import {
  type ModelUsage,
  type Options,
  query,
  type SDKAssistantMessageError,
  type SDKMessage,
  type SDKResultMessage,
} from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import type {
  AgentFailure,
  AgentFailureKind,
  AgentRunner,
  AgentUsage,
  DecideRequest,
  Decision,
  TaskOutcome,
  TaskSpec,
} from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { wrapUntrusted } from "./untrusted";

export type QueryFn = (args: { prompt: string; options: Options }) => AsyncIterable<SDKMessage>;
export type AgentEnv = Readonly<Record<string, string>>;
type Success = SDKResultMessage & { subtype: "success" };

interface Collected {
  readonly result?: SDKResultMessage;
  readonly assistantError?: SDKAssistantMessageError;
  readonly thrown?: unknown;
}

const ZERO_USAGE: AgentUsage = { costUsd: 0, inputTokens: 0, outputTokens: 0, durationMs: 0 };

// Text fallbacks: only for thrown errors with no result, and for the API error string the CLI
// puts in `result` of a success+is_error message. Typed SDK signals always win.
const TRANSIENT_TEXT =
  /API Error: (429|5\d\d)|overloaded|rate.?limit|fetch failed|ECONNREFUSED|ECONNRESET|EAI_AGAIN|ETIMEDOUT/i;
const AUTH_TEXT = /authentication_error|invalid api key|API Error: 401|oauth token/i;

const ASSISTANT_ERROR_KIND: Partial<Record<SDKAssistantMessageError, AgentFailureKind>> = {
  rate_limit: "transient",
  overloaded: "transient",
  server_error: "transient",
  authentication_failed: "auth",
  billing_error: "auth",
  oauth_org_not_allowed: "auth",
  account_on_hold: "auth",
  verification_required: "auth",
  cloud_credential_error: "auth",
  max_output_tokens: "truncated",
};

const AUTH_STARTUP = new Set([
  "gateway_signin_required",
  "gateway_access_denied",
  "org_verify_failed",
  "org_pin_api_key_conflict",
  "org_pin_mismatch",
  "org_config_refused",
]);
const TRANSIENT_STARTUP = new Set([
  "org_config_required_unavailable",
  "remote_settings_required_unavailable",
  "worktree_unverified",
]);

const ENV_ALLOWLIST = ["PATH", "HOME", "TMPDIR", "LANG", "CLAUDE_CODE_OAUTH_TOKEN"] as const;

/** Builds the child-process environment from an allowlist; nothing else leaks to the agent. */
export function agentEnv(source: Record<string, string | undefined>): AgentEnv {
  const env: Record<string, string> = {};
  for (const key of ENV_ALLOWLIST) {
    const value = source[key];
    if (value !== undefined) env[key] = value;
  }
  if (source.ANTHROPIC_API_KEY !== undefined) env.ANTHROPIC_API_KEY = source.ANTHROPIC_API_KEY;
  env.CLAUDE_AGENT_SDK_CLIENT_APP = "shipwright";
  return env;
}

async function collect(stream: AsyncIterable<SDKMessage>): Promise<Collected> {
  let result: SDKResultMessage | undefined;
  let assistantError: SDKAssistantMessageError | undefined;
  try {
    for await (const message of stream) {
      if (message.type === "result") result = message;
      else if (message.type === "assistant" && message.parent_tool_use_id === null) {
        // Only the final top-level turn counts: subagent errors and recovered errors are noise.
        assistantError = message.error;
      }
    }
  } catch (thrown) {
    // Single-shot query() throws after yielding an error result; keep both.
    return { result, assistantError, thrown };
  }
  return { result, assistantError };
}

function tokensOf(r: SDKResultMessage): { input: number; output: number } {
  const models: ModelUsage[] = Object.values(r.modelUsage ?? {});
  if (models.length > 0) {
    return models.reduce(
      (t, m) => ({
        input:
          t.input +
          (m.inputTokens ?? 0) +
          (m.cacheReadInputTokens ?? 0) +
          (m.cacheCreationInputTokens ?? 0),
        output: t.output + (m.outputTokens ?? 0),
      }),
      { input: 0, output: 0 },
    );
  }
  const u = r.usage;
  return {
    input:
      (u?.input_tokens ?? 0) +
      (u?.cache_read_input_tokens ?? 0) +
      (u?.cache_creation_input_tokens ?? 0),
    output: u?.output_tokens ?? 0,
  };
}

function usageOf(r: SDKResultMessage | undefined, startedAt: number): AgentUsage {
  const durationMs = Date.now() - startedAt;
  if (!r) return { ...ZERO_USAGE, durationMs };
  const t = tokensOf(r);
  return {
    costUsd: r.total_cost_usd ?? 0,
    inputTokens: t.input,
    outputTokens: t.output,
    durationMs,
  };
}

function classifyText(message: string): AgentFailureKind {
  if (AUTH_TEXT.test(message)) return "auth";
  if (TRANSIENT_TEXT.test(message)) return "transient";
  return "execution";
}

function messageOf(c: Collected): string {
  const r = c.result;
  if (r?.subtype === "success" && r.is_error && r.result) return r.result;
  if (r && r.subtype !== "success" && r.errors?.length) return r.errors.join("; ");
  if (c.thrown !== undefined)
    return c.thrown instanceof Error ? c.thrown.message : String(c.thrown);
  return r ? "agent run failed" : "stream ended without result";
}

function kindOf(c: Collected, message: string): AgentFailureKind {
  const typed = c.assistantError ? ASSISTANT_ERROR_KIND[c.assistantError] : undefined;
  if (typed) return typed;
  const r = c.result;
  if (r && r.subtype !== "success" && r.startup_failure_reason) {
    if (AUTH_STARTUP.has(r.startup_failure_reason)) return "auth";
    if (TRANSIENT_STARTUP.has(r.startup_failure_reason)) return "transient";
  }
  // errors[] on error results is not regex-classified: the SDK emits the typed signal for API errors.
  if (!r && c.thrown !== undefined) return classifyText(message);
  if (r?.subtype === "success" && r.is_error) return classifyText(message);
  return "execution";
}

function failure(
  c: Collected,
  usage: AgentUsage,
  aborted: boolean,
  timedOut: boolean,
): AgentFailure {
  const sessionId = c.result?.session_id;
  const fail = (kind: AgentFailureKind, message: string): AgentFailure =>
    sessionId ? { kind, message, usage, sessionId } : { kind, message, usage };
  if (timedOut) return fail("timeout", "agent call timed out");
  if (aborted) return fail("aborted", "agent call aborted");
  if (c.result?.stop_reason === "refusal") return fail("refusal", "model refused");
  if (c.result?.stop_reason === "max_tokens") return fail("truncated", "output hit max tokens");
  switch (c.result?.subtype) {
    case "error_max_turns":
      return fail("max_turns", "reached max turns");
    case "error_max_budget_usd":
      return fail("budget", "reached budget cap");
    case "error_max_structured_output_retries":
      return fail("schema", "no valid structured output");
  }
  const message = messageOf(c);
  return fail(kindOf(c, message), message);
}

export class AgentSdkRunner implements AgentRunner {
  constructor(
    private readonly env: AgentEnv,
    private readonly queryFn: QueryFn = query,
  ) {}

  async decide<T>(req: DecideRequest<T>): Promise<Result<Decision<T>, AgentFailure>> {
    let schema: Record<string, unknown>;
    try {
      schema = z.toJSONSchema(req.schema) as Record<string, unknown>;
    } catch (e) {
      return err({
        kind: "schema",
        message: `schema has no JSON Schema form: ${String(e)}`,
        usage: ZERO_USAGE,
      });
    }
    const run = await this.execute(wrapUntrusted(req.data), req.timeoutMs, undefined, {
      model: req.model,
      effort: req.effort,
      systemPrompt: req.instructions,
      permissionMode: "dontAsk",
      tools: [],
      allowedTools: [],
      strictMcpConfig: true,
      settingSources: [],
      persistSession: false,
      maxTurns: 3,
      maxBudgetUsd: req.maxBudgetUsd,
      outputFormat: { type: "json_schema", schema },
    });
    if (!run.ok) return run;
    const { result, usage } = run.value;
    const parsed = req.schema.safeParse(result.structured_output);
    if (!parsed.success) {
      return err({
        kind: "schema",
        message: parsed.error.message,
        usage,
        sessionId: result.session_id,
      });
    }
    return ok({ value: parsed.data, usage });
  }

  async runTask(spec: TaskSpec): Promise<Result<TaskOutcome, AgentFailure>> {
    const prompt = spec.data ? `${spec.prompt}\n\n${wrapUntrusted(spec.data)}` : spec.prompt;
    // settingSources "project": repos are the user's own and their CLAUDE.md guidance is needed,
    // but project settings can add hooks and permissions, so only run repos you trust.
    // persistSession stays on so max_turns/budget runs can be resumed; that needs HOME in env.
    const run = await this.execute(prompt, spec.timeoutMs, spec.signal, {
      model: spec.model,
      effort: spec.effort,
      cwd: spec.cwd,
      permissionMode: "dontAsk",
      allowedTools: [...spec.allowedTools],
      strictMcpConfig: true,
      settingSources: ["project"],
      maxTurns: spec.maxTurns,
      maxBudgetUsd: spec.maxBudgetUsd,
    });
    if (!run.ok) return run;
    const { result, usage } = run.value;
    return ok({
      summary: result.result,
      usage,
      turns: result.num_turns,
      sessionId: result.session_id,
    });
  }

  private async execute(
    prompt: string,
    timeoutMs: number,
    signal: AbortSignal | undefined,
    options: Options,
  ): Promise<Result<{ result: Success; usage: AgentUsage }, AgentFailure>> {
    const startedAt = Date.now();
    const controller = new AbortController();
    if (signal?.aborted) {
      return err({ kind: "aborted", message: "agent call aborted", usage: ZERO_USAGE });
    }
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, timeoutMs);
    const onAbort = () => controller.abort();
    signal?.addEventListener("abort", onAbort, { once: true });
    try {
      const collected = await collect(
        this.queryFn({
          prompt,
          options: { ...options, env: { ...this.env }, abortController: controller },
        }),
      );
      const r = collected.result;
      const usage = usageOf(r, startedAt);
      if (
        r?.subtype === "success" &&
        !r.is_error &&
        r.stop_reason !== "refusal" &&
        r.stop_reason !== "max_tokens"
      ) {
        return ok({ result: r, usage });
      }
      return err(failure(collected, usage, controller.signal.aborted && !timedOut, timedOut));
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    }
  }
}
