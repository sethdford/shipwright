import { describe, expect, test } from "bun:test";
import { z } from "zod";
import { AgentSdkRunner, type QueryFn } from "./agent-sdk-runner";

type Captured = { prompt: string; options: Record<string, unknown> };

function fakeQuery(messages: object[], opts: { throwAfter?: string } = {}) {
  const captured: Captured[] = [];
  const fn: QueryFn = (args) => {
    captured.push(args as unknown as Captured);
    return (async function* () {
      for (const m of messages) yield m as never;
      if (opts.throwAfter) throw new Error(opts.throwAfter);
    })();
  };
  return { fn, captured };
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
const runner = (fn: QueryFn) => new AgentSdkRunner(fn, {});

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
    expect(prompt).toContain("BEGIN DATA\nTitle: `rm -rf /`\n");
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
    const { fn } = fakeQuery([
      result({ subtype: "success", is_error: true, errors: [message], structured_output: {} }),
    ]);
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
    const r = await new AgentSdkRunner(fn, { PATH: "/bin" }).runTask(spec);
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
