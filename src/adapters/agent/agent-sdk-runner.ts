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
  AgentRunner,
  AgentUsage,
  DecideRequest,
  Decision,
  TaskOutcome,
  TaskSpec,
} from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { type Collected, failure, ZERO_USAGE } from "./agent-failure";
import { wrapUntrusted } from "./untrusted";

export type QueryFn = (args: { prompt: string; options: Options }) => AsyncIterable<SDKMessage>;
export type AgentEnv = Readonly<Record<string, string>>;
type Success = SDKResultMessage & { subtype: "success" };

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

function isCleanSuccess(r: SDKResultMessage | undefined): r is Success {
  return (
    r?.subtype === "success" &&
    !r.is_error &&
    r.stop_reason !== "refusal" &&
    r.stop_reason !== "max_tokens"
  );
}

/** Aborts the controller on timeout or when the caller's signal fires; `dispose` undoes both. */
function armGuard(timeoutMs: number, signal: AbortSignal | undefined) {
  const controller = new AbortController();
  const guard = {
    controller,
    timedOut: false,
    dispose: () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    },
  };
  const timer = setTimeout(() => {
    guard.timedOut = true;
    controller.abort();
  }, timeoutMs);
  const onAbort = () => controller.abort();
  signal?.addEventListener("abort", onAbort, { once: true });
  return guard;
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
    if (signal?.aborted) {
      return err({ kind: "aborted", message: "agent call aborted", usage: ZERO_USAGE });
    }
    const guard = armGuard(timeoutMs, signal);
    try {
      const collected = await collect(
        this.queryFn({
          prompt,
          options: { ...options, env: { ...this.env }, abortController: guard.controller },
        }),
      );
      const usage = usageOf(collected.result, startedAt);
      if (isCleanSuccess(collected.result)) return ok({ result: collected.result, usage });
      const { timedOut } = guard;
      return err(failure(collected, usage, guard.controller.signal.aborted && !timedOut, timedOut));
    } finally {
      guard.dispose();
    }
  }
}
