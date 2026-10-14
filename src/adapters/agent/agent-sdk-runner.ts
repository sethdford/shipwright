import {
  type Options,
  query,
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
type Success = SDKResultMessage & { subtype: "success" };

interface Collected {
  readonly result?: SDKResultMessage;
  readonly error?: unknown;
}

const ZERO_USAGE: AgentUsage = { costUsd: 0, inputTokens: 0, outputTokens: 0, durationMs: 0 };
const AUTH =
  /\b401\b|unauthori[sz]ed|invalid (api key|x-api-key)|authentication|run \/login|credentials/i;
const TRANSIENT =
  /overloaded|rate.?limit|\b(429|500|502|503|529)\b|ECONNRESET|ETIMEDOUT|network|socket hang up/i;

async function collect(stream: AsyncIterable<SDKMessage>): Promise<Collected> {
  let result: SDKResultMessage | undefined;
  try {
    for await (const message of stream) if (message.type === "result") result = message;
  } catch (error) {
    // Single-shot query() throws after yielding an error result; keep both.
    return { result, error };
  }
  return { result };
}

function usageOf(r: SDKResultMessage | undefined, startedAt: number): AgentUsage {
  return {
    costUsd: r?.total_cost_usd ?? 0,
    inputTokens: r?.usage?.input_tokens ?? 0,
    outputTokens: r?.usage?.output_tokens ?? 0,
    durationMs: Date.now() - startedAt,
  };
}

function classify(message: string): AgentFailureKind {
  if (AUTH.test(message)) return "auth";
  if (TRANSIENT.test(message)) return "transient";
  return "execution";
}

function errorMessage(c: Collected): string {
  const sdkErrors =
    c.result && "errors" in c.result ? (c.result.errors as string[] | undefined) : undefined;
  if (sdkErrors?.length) return sdkErrors.join("; ");
  return c.error instanceof Error ? c.error.message : "agent run failed";
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
  switch (c.result?.subtype) {
    case "error_max_turns":
      return fail("max_turns", "reached max turns");
    case "error_max_budget_usd":
      return fail("budget", "reached budget cap");
    case "error_max_structured_output_retries":
      return fail("schema", "no valid structured output");
  }
  const message = errorMessage(c);
  return fail(classify(message), message);
}

export class AgentSdkRunner implements AgentRunner {
  constructor(
    private readonly queryFn: QueryFn = query,
    private readonly env: Record<string, string | undefined>,
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
      allowedTools: [],
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
    const run = await this.execute(spec.prompt, spec.timeoutMs, spec.signal, {
      model: spec.model,
      effort: spec.effort,
      cwd: spec.cwd,
      permissionMode: "dontAsk",
      allowedTools: [...spec.allowedTools],
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
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, timeoutMs);
    signal?.addEventListener("abort", () => controller.abort(), { once: true });
    try {
      const options_ = { ...options, env: this.env, abortController: controller };
      const collected = await collect(this.queryFn({ prompt, options: options_ }));
      const r = collected.result;
      const usage = usageOf(r, startedAt);
      if (r?.subtype === "success" && !r.is_error && r.stop_reason !== "refusal") {
        return ok({ result: r, usage });
      }
      return err(failure(collected, usage, controller.signal.aborted && !timedOut, timedOut));
    } finally {
      clearTimeout(timer);
    }
  }
}
