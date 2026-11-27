import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import type { BenchArm, BenchTask } from "../../contexts/quality";
import { ok } from "../../shared/kernel/result";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { BunProcessRunner } from "../process/bun-process-runner";
import { agentEnv } from "./agent-env";
import { parseClaudeStream } from "./claude-stream";
import { startCommandLog } from "./command-log";
import { ProcessArmRunner } from "./process-arm-runner";

let tenv: TestEnv;
let w: string;
beforeEach(() => {
  tenv = createTestEnv();
  w = join(tenv.root, "w", "t1");
});
afterEach(() => tenv.cleanup());

const task = { id: "t1", problem: "fix the bug" } as BenchTask;
const arm = (over: Partial<BenchArm>): BenchArm => ({
  id: "a",
  label: "a",
  kind: "claude-code",
  model: "claude-opus-5-5",
  attempts: 1,
  timeoutMin: 2,
  estimateUsd: 1,
  argv: null,
  env: {},
  ...over,
});
const parent = { PATH: "/bin", GH_TOKEN: "secret", GITHUB_TOKEN: "secret", ANTHROPIC_API_KEY: "k" };

function make(
  script: ConstructorParameters<typeof FakeProcessRunner>[0],
  spent: number | null = 4,
) {
  const runner = new FakeProcessRunner(script);
  let t = 0;
  const cfg = {
    claudeBin: "claude",
    shipwrightBin: "/sw/scripts/sw",
    policyPath: "/sw/config/agent-permissions.json",
    env: parent,
    now: () => (t += 1000),
  };
  return { runner, arms: new ProcessArmRunner(runner, { between: async () => ok(spent) }, cfg) };
}

test("bare Claude Code: same model, the shared permission policy, prompt on stdin, no GitHub token", async () => {
  const tool = { type: "tool_use", name: "Bash", input: { command: "git log --all" } };
  const stdout = [
    JSON.stringify({ type: "assistant", message: { content: [tool] } }),
    JSON.stringify({ type: "result", total_cost_usd: 1.25, is_error: false }),
  ].join("\n");
  const { runner, arms } = make([
    { prefix: ["claude"], result: { exitCode: 0, stdout, stderr: "" } },
  ]);
  const out = await arms.run(arm({}), task, w);
  expect(out).toMatchObject({ status: "ok", costUsd: 1.25, commands: ["git log --all"] });
  expect(out.trajectory).toBe(stdout);
  const call = runner.calls[0];
  expect(call?.argv).toEqual([
    "claude",
    "-p",
    "--output-format",
    "stream-json",
    "--verbose",
    "--model",
    "claude-opus-5-5",
    "--settings",
    "/sw/config/agent-permissions.json",
  ]);
  expect(call?.cwd).toBe(w);
  expect(call?.env?.PATH).toMatch(/\/sw-bench-log-[^:/]+:\/bin$/);
  expect(call?.stdin).toContain("<issue>\nfix the bug\n</issue>");
  expect(call?.env?.GH_TOKEN).toBeUndefined();
  expect(call?.env?.GITHUB_TOKEN).toBeUndefined();
  expect(call?.env?.ANTHROPIC_API_KEY).toBe("k");
  expect(call?.timeoutMs).toBe(120_000);
});

test("Shipwright: local headless pipeline, attempts and arm env, spend from the ledger window", async () => {
  const { runner, arms } = make([
    { prefix: ["/sw/scripts/sw"], result: { exitCode: 0, stdout: "", stderr: "" } },
  ]);
  const a = arm({ kind: "shipwright", attempts: 3, env: { SHIPWRIGHT_LESSONS: "off" } });
  const out = await arms.run(a, task, w);
  expect(out).toMatchObject({ status: "ok", costUsd: 4 });
  const call = runner.calls[0];
  expect(call?.argv.slice(1, 4)).toEqual(["pipeline", "start", "--goal"]);
  expect(call?.argv).toContain("--local");
  expect(call?.argv).toContain("--headless");
  expect(call?.env).toMatchObject({ PIPELINE_ATTEMPTS: "3", SHIPWRIGHT_LESSONS: "off" });
  expect(call?.env?.GH_TOKEN).toBeUndefined();
});

test("timeouts, errors and a missing binary are outcomes, never throws", async () => {
  const { arms } = make([
    { prefix: ["claude"], result: { exitCode: 0, stdout: "", stderr: "", timedOut: true } },
  ]);
  expect((await arms.run(arm({}), task, w)).status).toBe("timeout");
  const failing = make([
    { prefix: ["claude"], result: { exitCode: 1, stdout: "{}", stderr: "boom" } },
  ]);
  expect(await failing.arms.run(arm({}), task, w)).toMatchObject({
    status: "error",
    note: "boom",
  });
  const missing = make([]);
  expect((await missing.arms.run(arm({}), task, w)).status).toBe("error");
});

test("parseClaudeStream reads the single-object format and streams", () => {
  const none = { commands: [] };
  expect(parseClaudeStream('{"total_cost_usd":0.5}')).toEqual({
    costUsd: 0.5,
    isError: false,
    ...none,
  });
  expect(parseClaudeStream('{"is_error":true}')).toEqual({ costUsd: null, isError: true, ...none });
  expect(parseClaudeStream("not json")).toEqual({ costUsd: null, isError: true, ...none });
  const read = { type: "tool_use", name: "Read", input: { file_path: "/x/repos/r.git/HEAD" } };
  const stream = [
    JSON.stringify({ type: "assistant", message: { content: [{ type: "text" }, read] } }),
    "garbage",
  ].join("\n");
  expect(parseClaudeStream(stream)).toEqual({
    costUsd: null,
    isError: true,
    commands: ["Read /x/repos/r.git/HEAD"],
  });
});

test("the command log records git calls an arm makes", async () => {
  const runner = new BunProcessRunner();
  let t = 0;
  const PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";
  const env = { PATH, HOME: tenv.home };
  const cfg = {
    claudeBin: "claude",
    shipwrightBin: "sw",
    policyPath: "p",
    env,
    now: () => (t += 1000),
  };
  const arms = new ProcessArmRunner(runner, { between: async () => ok(null) }, cfg);
  mkdirSync(w, { recursive: true });
  const out = await arms.run(arm({ kind: "command", argv: ["git", "--version"] }), task, w);
  expect(out.status).toBe("ok");
  expect(out.commands).toEqual(["git --version"]);
});

test("a wrapper runs the real tool by absolute path, so PATH order cannot make it loop", async () => {
  const log = await startCommandLog("/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin");
  expect(log.active).toBe(true);
  const dir = log.path.split(":")[0] ?? "";
  const runner = new BunProcessRunner();
  // Only the wrapper dir on PATH: a wrapper that looked git up by name would find itself forever.
  const r = await runner.run({
    argv: [join(dir, "git"), "--version"],
    env: { PATH: dir },
    timeoutMs: 10_000,
  });
  expect(r.timedOut).toBe(false);
  expect(r.stdout).toStartWith("git version");
  expect(await log.read()).toEqual(["git --version"]);
  await log.remove();
  expect(existsSync(dir)).toBe(false);
});

test("agentEnv drops GitHub tokens and adds the arm's variables", () => {
  const env = agentEnv(
    { ...parent, GH_ENTERPRISE_TOKEN: "x", UNSET: undefined },
    { SHIPWRIGHT_X: "1" },
  );
  expect(env).toEqual({ PATH: "/bin", ANTHROPIC_API_KEY: "k", SHIPWRIGHT_X: "1" });
});
