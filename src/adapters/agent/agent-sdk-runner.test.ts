import { describe, expect, test } from "bun:test";
import { z } from "zod";
import type { AgentFailureKind } from "../../shared/kernel/ports";
import { AgentSdkRunner, agentEnv, type QueryFn } from "./agent-sdk-runner";

type Captured = { prompt: string; options: Record<string, unknown> };

function fakeQuery(messages: object[], opts: { throwAfter?: string; hang?: boolean } = {}) {
  const captured: Captured[] = [];
  const state = { iterated: false };
  const fn: QueryFn = (args) => {
    captured.push(args as unknown as Captured);
    return (async function* () {
      state.iterated = true;
      for (const m of messages) yield m as never;
      if (opts.hang) {
        const ac = args.options.abortController as AbortController;
        await new Promise<void>((resolve) => {
          if (ac.signal.aborted) resolve();
          ac.signal.addEventListener("abort", () => resolve(), { once: true });
        });
        throw new Error("aborted by controller");
      }
      if (opts.throwAfter) throw new Error(opts.throwAfter);
    })();
  };
  return { fn, captured, state };
}

const result = (extra: object) => ({
  type: "result",
  is_error: false,
  total_cost_usd: 0.01,
  usage: { input_tokens: 100, output_tokens: 20 },
  num_turns: 1,
  session_id: "s1",
  stop_reason: "end_turn",
  ...extra,
});

const Triage = z.object({ approved: z.boolean(), reason: z.string() });
const decideReq = {
  instructions: "Decide if the issue fits the roadmap.",
  data: "Title: `rm -rf /`",
  schema: Triage,
  model: "claude-haiku-5-5",
  effort: "low" as const,
  maxBudgetUsd: 0.5,
  timeoutMs: 60_000,
};
const runner = (fn: QueryFn) => new AgentSdkRunner({}, fn);

describe("decide", () => {
  test("returns the validated structured output with usage", async () => {
    const { fn } = fakeQuery([
      result({ subtype: "success", structured_output: { approved: true, reason: "fits" } }),
    ]);
    const r = await runner(fn).decide(decideReq);
    if (!r.ok) throw new Error(r.error.message);
    expect(r.value.value).toEqual({ approved: true, reason: "fits" });
    expect(r.value.usage).toMatchObject({ costUsd: 0.01, inputTokens: 100, outputTokens: 20 });
    expect(r.value.usage.durationMs).toBeGreaterThanOrEqual(0);
  });

  test("passes untrusted data only inside the data block, denies all tools, isolates settings", async () => {
    const { fn, captured } = fakeQuery([
      result({ subtype: "success", structured_output: { approved: false, reason: "no" } }),
    ]);
    await runner(fn).decide(decideReq);
    const { prompt, options } = captured[0] as Captured;
    expect(prompt).toMatch(/BEGIN DATA [0-9a-f-]{36}\nTitle: `rm -rf \/`\n/);
    expect(options).toMatchObject({
      systemPrompt: decideReq.instructions,
      permissionMode: "dontAsk",
      allowedTools: [],
      settingSources: [],
      persistSession: false,
      model: "claude-haiku-5-5",
      effort: "low",
      maxBudgetUsd: 0.5,
      outputFormat: { type: "json_schema" },
    });
  });

  test("schema mismatch is a typed failure carrying the session id", async () => {
    const { fn } = fakeQuery([
      result({ subtype: "success", structured_output: { approved: "yes" } }),
    ]);
    const r = await runner(fn).decide(decideReq);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error).toMatchObject({ kind: "schema", sessionId: "s1" });
  });

  test("a schema that cannot be expressed as JSON Schema fails before calling Claude", async () => {
    const { fn, captured } = fakeQuery([]);
    const r = await runner(fn).decide({
      ...decideReq,
      schema: z.string().transform((s) => s.length),
    });
    expect(!r.ok && r.error.kind).toBe("schema");
    expect(captured).toHaveLength(0);
  });

  test("refusal is reported as refusal even though the SDK throws afterwards", async () => {
    const { fn } = fakeQuery(
      [result({ subtype: "error_during_execution", is_error: true, stop_reason: "refusal" })],
      { throwAfter: "Claude Code process exited with code 1" },
    );
    const r = await runner(fn).decide(decideReq);
    if (r.ok) throw new Error("expected failure");
    expect(r.error).toMatchObject({ kind: "refusal", message: "model refused", sessionId: "s1" });
    expect(r.error.usage.costUsd).toBe(0.01);
  });

  test("budget exhaustion maps to budget", async () => {
    const { fn } = fakeQuery([result({ subtype: "error_max_budget_usd", is_error: true })], {
      throwAfter: "budget",
    });
    const r = await runner(fn).decide(decideReq);
    expect(!r.ok && r.error.kind).toBe("budget");
  });

  test.each([
    ["API Error: 529 overloaded_error", "transient"],
    ["API Error: 429 rate_limit_error", "transient"],
    ["Invalid API key · Please run /login", "auth"],
    ["Unexpected tool failure", "execution"],
  ])("classifies SDK error %p as %p", async (message, kind) => {
    const { fn } = fakeQuery([result({ subtype: "success", is_error: true, result: message })]);
    const r = await runner(fn).decide(decideReq);
    if (r.ok) throw new Error("expected failure");
    expect(r.error).toMatchObject({ kind, message });
  });

  test("a crash with no result message is an execution failure with zero cost and no session", async () => {
    const { fn } = fakeQuery([], { throwAfter: "Claude Code process exited with code 1" });
    const r = await runner(fn).decide(decideReq);
    if (r.ok) throw new Error("expected failure");
    expect(r.error.kind).toBe("execution");
    expect(r.error.message).toBe("Claude Code process exited with code 1");
    expect(r.error.usage.costUsd).toBe(0);
    expect(r.error.sessionId).toBeUndefined();
  });
});

describe("runTask", () => {
  const spec = {
    prompt: "Implement the plan",
    cwd: "/wt/issue-1",
    model: "claude-opus-5-5",
    effort: "xhigh" as const,
    allowedTools: ["Read", "Edit", "Bash(bun test *)"],
    maxTurns: 40,
    maxBudgetUsd: 5,
    timeoutMs: 600_000,
  };

  test("runs in the worktree with only the allowed tools and returns a summary", async () => {
    const { fn, captured } = fakeQuery([
      result({ subtype: "success", result: "done", num_turns: 7 }),
    ]);
    const r = await new AgentSdkRunner({ PATH: "/bin" }, fn).runTask(spec);
    if (!r.ok) throw new Error(r.error.message);
    expect(r.value).toMatchObject({ summary: "done", turns: 7, sessionId: "s1" });
    expect(r.value.usage.costUsd).toBe(0.01);
    expect((captured[0] as Captured).options).toMatchObject({
      cwd: "/wt/issue-1",
      permissionMode: "dontAsk",
      allowedTools: ["Read", "Edit", "Bash(bun test *)"],
      settingSources: ["project"],
      env: { PATH: "/bin" },
    });
  });

  test("max turns maps to max_turns and keeps the session id so the run can be resumed", async () => {
    const { fn } = fakeQuery([result({ subtype: "error_max_turns", is_error: true })], {
      throwAfter: "Reached maximum number of turns",
    });
    const r = await runner(fn).runTask(spec);
    if (r.ok) throw new Error("expected failure");
    expect(r.error).toMatchObject({ kind: "max_turns", sessionId: "s1" });
  });
});

const assistantErr = (error: string, parent: string | null = null) => ({
  type: "assistant",
  error,
  parent_tool_use_id: parent,
  session_id: "s1",
});
const assistantOk = () => ({ type: "assistant", parent_tool_use_id: null, session_id: "s1" });
const failSuccess = (text: string) => result({ subtype: "success", is_error: true, result: text });

describe("typed failure classification", () => {
  test("success+is_error with 529 text and a throw is transient, message is the result text", async () => {
    const { fn } = fakeQuery([failSuccess("API Error: 529 Overloaded")], { throwAfter: "exit 1" });
    const r = await runner(fn).decide(decideReq);
    if (r.ok) throw new Error("expected failure");
    expect(r.error).toMatchObject({ kind: "transient", message: "API Error: 529 Overloaded" });
  });

  test.each([
    ["rate_limit", "transient"],
    ["overloaded", "transient"],
    ["server_error", "transient"],
    ["authentication_failed", "auth"],
    ["billing_error", "auth"],
    ["oauth_org_not_allowed", "auth"],
    ["account_on_hold", "auth"],
    ["max_output_tokens", "truncated"],
    ["unknown", "execution"],
  ])("assistant error %p maps to %p (typed signal beats text)", async (e, kind) => {
    const { fn } = fakeQuery([assistantErr(e), failSuccess("something opaque")]);
    const r = await runner(fn).decide(decideReq);
    if (r.ok) throw new Error("expected failure");
    expect(r.error.kind).toBe(kind as AgentFailureKind);
  });

  test("subagent assistant error is ignored; final execution error stays execution", async () => {
    const { fn } = fakeQuery([
      assistantErr("overloaded", "toolu_1"),
      result({ subtype: "error_during_execution", is_error: true, errors: ["boom"] }),
    ]);
    const r = await runner(fn).decide(decideReq);
    expect(!r.ok && r.error.kind).toBe("execution");
  });

  test("a top-level error cleared by a later clean top-level assistant message is dropped", async () => {
    const { fn } = fakeQuery([
      assistantErr("rate_limit"),
      assistantOk(),
      result({ subtype: "error_during_execution", is_error: true, errors: ["boom"] }),
    ]);
    const r = await runner(fn).decide(decideReq);
    expect(!r.ok && r.error.kind).toBe("execution");
  });

  test.each([
    ["org_config_refused", "auth"],
    ["org_config_required_unavailable", "transient"],
    ["remote_settings_required_unavailable", "transient"],
    ["worktree_unverified", "transient"],
  ])("startup_failure_reason %p is %p", async (reason, kind) => {
    const { fn } = fakeQuery([
      result({
        subtype: "error_during_execution",
        is_error: true,
        errors: ["x"],
        startup_failure_reason: reason,
      }),
    ]);
    const r = await runner(fn).decide(decideReq);
    expect(!r.ok && r.error.kind).toBe(kind as AgentFailureKind);
  });

  test("startup_failure_reason gateway_signin_required is auth", async () => {
    const { fn } = fakeQuery([
      result({
        subtype: "error_during_execution",
        is_error: true,
        errors: ["sign in"],
        startup_failure_reason: "gateway_signin_required",
      }),
    ]);
    const r = await runner(fn).decide(decideReq);
    expect(!r.ok && r.error.kind).toBe("auth");
  });

  test("errors[] on error results are joined into the message", async () => {
    const { fn } = fakeQuery([
      result({ subtype: "error_during_execution", is_error: true, errors: ["a", "b"] }),
    ]);
    const r = await runner(fn).decide(decideReq);
    expect(!r.ok && r.error.message).toBe("a; b");
  });

  test.each([
    ["ENOENT credentials.json not found", "execution"],
    ["wrote 500 lines", "execution"],
    ["fetch failed", "transient"],
    ["API Error: 401 authentication_error", "auth"],
  ])("thrown error with no result %p classifies as %p", async (message, kind) => {
    const { fn } = fakeQuery([], { throwAfter: message });
    const r = await runner(fn).decide(decideReq);
    expect(!r.ok && r.error.kind).toBe(kind as AgentFailureKind);
  });

  test("tightened text fallback does not misclassify incidental words", async () => {
    const { fn } = fakeQuery([failSuccess("the file credentials.json has 500 lines")]);
    const r = await runner(fn).decide(decideReq);
    expect(!r.ok && r.error.kind).toBe("execution");
  });

  test("empty stream without result or throw is an execution failure", async () => {
    const { fn } = fakeQuery([]);
    const r = await runner(fn).decide(decideReq);
    if (r.ok) throw new Error("expected failure");
    expect(r.error).toMatchObject({ kind: "execution", message: "stream ended without result" });
  });

  test("max_tokens stop on success is a truncated failure", async () => {
    const { fn } = fakeQuery([
      result({ subtype: "success", stop_reason: "max_tokens", structured_output: {} }),
    ]);
    const r = await runner(fn).decide(decideReq);
    expect(!r.ok && r.error.kind).toBe("truncated");
  });

  test("error_max_structured_output_retries maps to schema", async () => {
    const { fn } = fakeQuery([
      result({ subtype: "error_max_structured_output_retries", is_error: true }),
    ]);
    const r = await runner(fn).decide(decideReq);
    expect(!r.ok && r.error.kind).toBe("schema");
  });
});

describe("usage", () => {
  test("sums modelUsage across models including cache tokens", async () => {
    const mu = (i: number, o: number, cr: number, cc: number) => ({
      inputTokens: i,
      outputTokens: o,
      cacheReadInputTokens: cr,
      cacheCreationInputTokens: cc,
    });
    const { fn } = fakeQuery([
      result({
        subtype: "success",
        structured_output: { approved: true, reason: "x" },
        modelUsage: { a: mu(10, 5, 100, 20), b: mu(1, 2, 3, 4) },
      }),
    ]);
    const r = await runner(fn).decide(decideReq);
    if (!r.ok) throw new Error(r.error.message);
    expect(r.value.usage).toMatchObject({ inputTokens: 138, outputTokens: 7 });
  });
});

describe("abort and timeout", () => {
  const spec = {
    prompt: "p",
    cwd: "/w",
    model: "m",
    effort: "low" as const,
    allowedTools: [],
    maxTurns: 1,
    maxBudgetUsd: 1,
    timeoutMs: 60_000,
  };

  test("pre-aborted signal never iterates the query", async () => {
    const { fn, state } = fakeQuery([result({ subtype: "success", result: "x" })]);
    const ac = new AbortController();
    ac.abort();
    const r = await runner(fn).runTask({ ...spec, signal: ac.signal });
    expect(!r.ok && r.error.kind).toBe("aborted");
    expect(state.iterated).toBe(false);
  });

  test("external abort mid-stream is aborted", async () => {
    const { fn } = fakeQuery([], { hang: true });
    const ac = new AbortController();
    const p = runner(fn).runTask({ ...spec, signal: ac.signal });
    setTimeout(() => ac.abort(), 10);
    const r = await p;
    expect(!r.ok && r.error.kind).toBe("aborted");
  });

  test("timeout is timeout", async () => {
    const { fn } = fakeQuery([], { hang: true });
    const r = await runner(fn).runTask({ ...spec, timeoutMs: 20 });
    expect(!r.ok && r.error.kind).toBe("timeout");
  });
});

describe("guard cleanup", () => {
  const spec = {
    prompt: "p",
    cwd: "/w",
    model: "m",
    effort: "low" as const,
    allowedTools: [],
    maxTurns: 1,
    maxBudgetUsd: 1,
    timeoutMs: 60_000,
  };
  const ok = () => [result({ subtype: "success", result: "x" })];
  const controllerOf = (c: { options: Record<string, unknown> }) =>
    c.options.abortController as AbortController;

  test("removes its listener from the caller's signal after a run", async () => {
    const { fn, captured } = fakeQuery(ok());
    const caller = new AbortController();
    const removed: string[] = [];
    const original = caller.signal.removeEventListener.bind(caller.signal);
    caller.signal.removeEventListener = ((...args: Parameters<typeof original>) => {
      removed.push(String(args[0]));
      return original(...args);
    }) as typeof original;
    const r = await runner(fn).runTask({ ...spec, signal: caller.signal });
    expect(r.ok).toBe(true);
    expect(removed).toEqual(["abort"]);
    caller.abort();
    expect(controllerOf(captured[0] as Captured).signal.aborted).toBe(false);
  });

  test("clears the timeout timer once the run completes", async () => {
    const { fn, captured } = fakeQuery(ok());
    const r = await runner(fn).runTask({ ...spec, timeoutMs: 30 });
    expect(r.ok).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(controllerOf(captured[0] as Captured).signal.aborted).toBe(false);
  });

  test("timeout wins when the caller also aborts", async () => {
    const fn: QueryFn = (args) =>
      (async function* () {
        const ac = args.options.abortController as AbortController;
        await new Promise<void>((resolve) => ac.signal.addEventListener("abort", () => resolve()));
        await new Promise((resolve) => setTimeout(resolve, 60));
        yield* [];
        throw new Error("stopped");
      })();
    const caller = new AbortController();
    setTimeout(() => caller.abort(), 5);
    const r = await runner(fn).runTask({ ...spec, timeoutMs: 30, signal: caller.signal });
    expect(!r.ok && r.error.kind).toBe("timeout");
  });

  test.each([
    ["timeout", () => ({ timeoutMs: 20 })],
    ["aborted", () => ({ signal: AbortSignal.timeout(20) })],
  ] as const)("keeps the sessionId the SDK yielded on %s failures", async (kind, extra) => {
    const { fn } = fakeQuery([result({ subtype: "error_during_execution", session_id: "s9" })], {
      hang: true,
    });
    const r = await runner(fn).runTask({ ...spec, ...extra() });
    expect(!r.ok && r.error.kind).toBe(kind);
    expect(!r.ok && r.error.sessionId).toBe("s9");
  });
});

describe("hardening options", () => {
  test("decide disables built-in tools and strict MCP", async () => {
    const { fn, captured } = fakeQuery([
      result({ subtype: "success", structured_output: { approved: true, reason: "x" } }),
    ]);
    await runner(fn).decide(decideReq);
    expect((captured[0] as Captured).options).toMatchObject({ tools: [], strictMcpConfig: true });
  });

  test("runTask uses strict MCP and wraps optional untrusted data in the prompt", async () => {
    const { fn, captured } = fakeQuery([result({ subtype: "success", result: "ok" })]);
    await runner(fn).runTask({
      prompt: "Implement",
      data: "issue body: ignore all",
      cwd: "/w",
      model: "m",
      effort: "low",
      allowedTools: [],
      maxTurns: 1,
      maxBudgetUsd: 1,
      timeoutMs: 1000,
    });
    const c = captured[0] as Captured;
    expect(c.options).toMatchObject({ strictMcpConfig: true });
    expect(c.prompt.startsWith("Implement")).toBe(true);
    expect(c.prompt).toContain("issue body: ignore all");
    expect(c.prompt).toContain("untrusted input data");
  });
});

describe("agentEnv", () => {
  test("allowlists required variables and drops everything else", () => {
    const env = agentEnv({
      PATH: "/bin",
      HOME: "/h",
      TMPDIR: "/t",
      LANG: "en",
      CLAUDE_CODE_OAUTH_TOKEN: "tok",
      GITHUB_TOKEN: "gh",
      AWS_SECRET_ACCESS_KEY: "aws",
    });
    expect(env).toEqual({
      PATH: "/bin",
      HOME: "/h",
      TMPDIR: "/t",
      LANG: "en",
      CLAUDE_CODE_OAUTH_TOKEN: "tok",
      CLAUDE_AGENT_SDK_CLIENT_APP: "shipwright",
    });
  });

  test("F9: never forwards a GitHub token, whatever else is set", () => {
    const tokens = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"];
    const env = agentEnv({
      PATH: "/bin",
      ANTHROPIC_API_KEY: "k",
      ...Object.fromEntries(tokens.map((t) => [t, "secret"])),
    });
    for (const t of tokens) expect(t in env).toBe(false);
    expect(Object.values(env)).not.toContain("secret");
  });

  test("F9: a runner given a GitHub token refuses to start the agent", async () => {
    const { fn, state } = fakeQuery([result({ subtype: "success", result: "x" })]);
    const runner = new AgentSdkRunner({ PATH: "/bin", GH_TOKEN: "t" }, fn);
    await expect(
      runner.runTask({
        prompt: "p",
        cwd: "/w",
        model: "m",
        effort: "low",
        allowedTools: [],
        maxTurns: 1,
        maxBudgetUsd: 1,
        timeoutMs: 1000,
      }),
    ).rejects.toThrow(/F9/);
    expect(state.iterated).toBe(false);
  });

  test("includes ANTHROPIC_API_KEY only when present", () => {
    expect(agentEnv({ ANTHROPIC_API_KEY: "k" })).toMatchObject({ ANTHROPIC_API_KEY: "k" });
    expect("ANTHROPIC_API_KEY" in agentEnv({})).toBe(false);
  });
});
