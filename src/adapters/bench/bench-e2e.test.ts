import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  type BenchArm,
  type BenchPorts,
  type BenchTask,
  buildBenchReport,
  oracleOk,
  runBenchmark,
  validateTask,
} from "../../contexts/quality";
import { ok } from "../../shared/kernel/result";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { BunProcessRunner } from "../process/bun-process-runner";
import { GitBenchWorkspaces } from "./git-bench-workspaces";
import { JsonlBenchStore } from "./jsonl-bench-store";
import { ProcessArmRunner } from "./process-arm-runner";
import { ProcessBenchGrader } from "./process-bench-grader";

// End to end with real git and real processes, all under a throwaway HOME: a tiny repo with a
// bug, a gold fix with a test, and two "agents": one that copies the fix in, one that does nothing.

let env: TestEnv;
let toolEnv: Record<string, string>;
const runner = new BunProcessRunner();

const BUGGY = 'echo "$(( $1 - $2 ))"\n';
const FIXED = 'echo "$(( $1 + $2 ))"\n';
const TEST = '[ "$(bash add.sh 2 3)" = "5" ] || { echo "add is wrong" >&2; exit 1; }\n';

async function git(cwd: string, ...args: string[]): Promise<string> {
  const r = await runner.run({ argv: ["git", ...args], cwd, env: toolEnv, timeoutMs: 30_000 });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
}

async function makeRepo(): Promise<{
  repo: string;
  base: string;
  gold: string;
  testPatch: string;
}> {
  const repo = join(env.root, "upstream");
  mkdirSync(repo);
  await git(repo, "init", "--quiet", "-b", "main");
  await git(repo, "config", "user.email", "t@t.invalid");
  await git(repo, "config", "user.name", "t");
  writeFileSync(join(repo, "add.sh"), BUGGY);
  await git(repo, "add", "-A");
  await git(repo, "commit", "--quiet", "-m", "base");
  const base = await git(repo, "rev-parse", "HEAD");
  writeFileSync(join(repo, "add.sh"), FIXED);
  writeFileSync(join(repo, "add-test.sh"), TEST);
  await git(repo, "add", "-A");
  await git(repo, "commit", "--quiet", "-m", "fix");
  const gold = await git(repo, "rev-parse", "HEAD");
  const testPatch = `${await git(repo, "diff", base, gold, "--", "add-test.sh")}\n`;
  return { repo, base, gold, testPatch };
}

const arm = (id: string, argv: string[]): BenchArm => ({
  id,
  label: id,
  kind: "command",
  model: "none",
  attempts: 1,
  timeoutMin: 1,
  estimateUsd: 1,
  argv,
  env: {},
});

function ports(): BenchPorts {
  const now = () => Date.now();
  const spend = { between: async () => ok(null) };
  const cfg = { claudeBin: "claude", shipwrightBin: "sw", policyPath: "p", env: toolEnv, now };
  return {
    now,
    workspaces: new GitBenchWorkspaces(runner, join(env.root, "bench"), toolEnv),
    grader: new ProcessBenchGrader(runner, toolEnv),
    store: new JsonlBenchStore(join(env.root, "results")),
    arms: new ProcessArmRunner(runner, spend, cfg),
  };
}

beforeEach(() => {
  env = createTestEnv();
  toolEnv = {
    PATH: "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
    HOME: env.home,
    GIT_CONFIG_NOSYSTEM: "1",
  };
});
afterEach(() => env.cleanup());

test("runs, grades, resumes and reports a holdout task end to end", async () => {
  const { repo, base, gold, testPatch } = await makeRepo();
  const fixFile = join(env.root, "fixed.sh");
  writeFileSync(fixFile, FIXED);
  const task: BenchTask = {
    id: "add-1",
    suite: "holdout",
    repo,
    baseCommit: base,
    problem: "add.sh subtracts instead of adding",
    setup: [],
    testPatch,
    testCommands: [["bash", "add-test.sh"]],
    goldCommit: gold,
    createdAt: null,
  };
  const arms = [arm("fixer", ["cp", fixFile, "{workdir}/add.sh"]), arm("noop", ["true"])];
  const p = ports();

  expect(oracleOk(await validateTask(task, p))).toBe(true);

  const r = await runBenchmark({ tasks: [task], arms, trials: 1, budgetUsd: 10 }, p);
  expect(r.ok && r.value).toMatchObject({ ran: 2, stoppedForBudget: false });
  const rows = await p.store.rows();
  if (!rows.ok) throw new Error(rows.error.message);
  const outcome = Object.fromEntries(rows.value.map((x) => [x.armId, [x.resolved, x.note]]));
  expect(outcome.fixer).toEqual([true, "1 test command(s) passed"]);
  expect(outcome.noop).toEqual([false, "empty patch"]);
  const patch = readFileSync(join(env.root, "results/patches/fixer/add-1.t1.diff"), "utf8");
  expect(patch).toContain('+echo "$(( $1 + $2 ))"');

  const again = await runBenchmark({ tasks: [task], arms, trials: 1, budgetUsd: 10 }, p);
  expect(again.ok && again.value.ran).toBe(0);

  const report = buildBenchReport({ name: "e2e", tasks: [task] }, arms, "noop", rows.value, 1, 0);
  expect(report.pairs[0]).toMatchObject({ armId: "fixer", wins: 1, losses: 0 });
}, 60_000);

test("an agent that edits the hidden test file cannot pass by it", async () => {
  const { repo, base, testPatch } = await makeRepo();
  const cheat = join(env.root, "cheat-test.sh");
  writeFileSync(cheat, "exit 0\n");
  const task: BenchTask = {
    id: "add-2",
    suite: "holdout",
    repo,
    baseCommit: base,
    problem: "p",
    setup: [],
    testPatch,
    testCommands: [["bash", "add-test.sh"]],
    goldCommit: null,
    createdAt: null,
  };
  const p = ports();
  const arms = [arm("cheater", ["cp", cheat, "{workdir}/add-test.sh"])];
  await runBenchmark({ tasks: [task], arms, trials: 1, budgetUsd: 10 }, p);
  const rows = await p.store.rows();
  expect(rows.ok && rows.value[0]?.resolved).toBe(false);
}, 60_000);

test("the budget stops a run before it starts", async () => {
  const { repo, base, testPatch } = await makeRepo();
  const task = {
    id: "add-3",
    suite: "holdout",
    repo,
    baseCommit: base,
    problem: "p",
    setup: [],
    testPatch,
    testCommands: [["bash", "add-test.sh"]],
    goldCommit: null,
    createdAt: null,
  } as BenchTask;
  const r = await runBenchmark(
    { tasks: [task], arms: [arm("noop", ["true"])], trials: 2, budgetUsd: 1.5 },
    ports(),
  );
  expect(r.ok && r.value).toMatchObject({ ran: 1, stoppedForBudget: true });
}, 60_000);
