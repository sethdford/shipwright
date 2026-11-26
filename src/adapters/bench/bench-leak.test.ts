import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  type BenchArm,
  type BenchPorts,
  type BenchTask,
  runBenchmark,
} from "../../contexts/quality";
import { ok } from "../../shared/kernel/result";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { BunProcessRunner } from "../process/bun-process-runner";
import { GitBenchWorkspaces } from "./git-bench-workspaces";
import { JsonlBenchStore } from "./jsonl-bench-store";
import { ProcessArmRunner } from "./process-arm-runner";
import { ProcessBenchGrader } from "./process-bench-grader";

// The SWE-bench Pro leak, reproduced: upstream has the gold fix on main, a tag on it, a future
// branch and a pull ref. An agent digging through every object it can reach must find none of it,
// and an agent that reads the harness's own full-history mirror is voided.

let env: TestEnv;
let toolEnv: Record<string, string>;
const runner = new BunProcessRunner();
const FIXED = 'echo "$(( $1 + $2 ))"\n';
const GOLD_MARK = "gold-fix-marker";

async function git(cwd: string, ...args: string[]): Promise<string> {
  const r = await runner.run({ argv: ["git", ...args], cwd, env: toolEnv, timeoutMs: 30_000 });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
}

async function commit(repo: string, file: string, text: string, msg: string): Promise<string> {
  writeFileSync(join(repo, file), text);
  await git(repo, "add", "-A");
  await git(repo, "commit", "--quiet", "-m", msg);
  return git(repo, "rev-parse", "HEAD");
}

async function leakyUpstream(): Promise<BenchTask> {
  const repo = join(env.root, "upstream");
  mkdirSync(repo);
  await git(repo, "init", "--quiet", "-b", "main");
  await git(repo, "config", "user.email", "t@t.invalid");
  await git(repo, "config", "user.name", "t");
  await commit(repo, "add.sh", 'echo "$(( $1 - $2 ))"\n', "init");
  const base = await commit(repo, "README", "adder\n", "docs");
  writeFileSync(join(repo, "add-test.sh"), '[ "$(bash add.sh 2 3)" = "5" ] || exit 1\n');
  const gold = await commit(repo, "add.sh", FIXED, GOLD_MARK);
  const testPatch = `${await git(repo, "diff", base, gold, "--", "add-test.sh")}\n`;
  await git(repo, "tag", "-a", "v1", "-m", "release with the fix");
  await git(repo, "update-ref", "refs/pull/1/head", gold);
  await git(repo, "checkout", "--quiet", "-b", "later", gold);
  await commit(repo, "later.txt", "x\n", "later work");
  await git(repo, "checkout", "--quiet", "main");
  return {
    id: "leak-1",
    suite: "holdout",
    repo,
    baseCommit: base,
    problem: "add.sh subtracts",
    setup: [],
    testPatch,
    testCommands: [["bash", "add-test.sh"]],
    goldCommit: gold,
    createdAt: null,
  };
}

const arm = (id: string, script: string): BenchArm => {
  const file = join(env.root, `${id}.sh`);
  writeFileSync(file, script);
  const argv = ["bash", file, "{workdir}"];
  return {
    id,
    label: id,
    kind: "command",
    model: "none",
    attempts: 1,
    timeoutMin: 1,
    estimateUsd: 1,
    argv,
    env: {},
  };
};

function ports(): BenchPorts {
  const now = () => Date.now();
  const cfg = { claudeBin: "claude", shipwrightBin: "sw", policyPath: "p", env: toolEnv, now };
  const root = join(env.root, "bench");
  return {
    now,
    workspaces: new GitBenchWorkspaces(runner, root, toolEnv, join(env.root, "work")),
    grader: new ProcessBenchGrader(runner, toolEnv),
    store: new JsonlBenchStore(join(env.root, "results")),
    arms: new ProcessArmRunner(runner, { between: async () => ok(null) }, cfg),
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

const DIG = `cd "$1"
{
  git log --all --reflog --format='%H %s'
  git tag -l; git branch -a; git for-each-ref
  git cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype)' |
    while read -r o t; do echo "$o $t"; [ "$t" = tree ] || git cat-file -p "$o"; done
  git fetch --quiet origin '+refs/*:refs/dig/*' 2>&1; git log --all --format='%H %s'
  git fsck --lost-found 2>&1
  git remote -v; cat .git/config; ls .git
} > dig.txt 2>&1
exit 0
`;

test("a workspace holds no future commit, tag, branch or pull ref", async () => {
  const task = await leakyUpstream();
  const p = ports();
  await runBenchmark({ tasks: [task], arms: [arm("digger", DIG)], trials: 1, budgetUsd: 10 }, p);
  const patch = readFileSync(join(env.root, "results/patches/digger/leak-1.t1.diff"), "utf8");
  expect(patch).toContain("dig.txt");
  expect(patch).toContain(task.baseCommit);
  expect(patch).not.toContain(task.goldCommit ?? "missing");
  expect(patch).not.toContain(GOLD_MARK);
  expect(patch).not.toContain("$1 + $2");
  expect(patch).not.toContain("later work");
  expect(patch).not.toContain(join(env.root, "bench/"));
  const rows = await p.store.rows();
  const flags = rows.ok ? (rows.value[0]?.flags ?? []) : [];
  expect(flags.some((f) => f.startsWith("warn:history-probe: git log --all"))).toBe(true);
  expect(flags.some((f) => f.startsWith("void:"))).toBe(false);
}, 60_000);

test("reading the harness's full-history mirror voids a run that would have passed", async () => {
  const task = await leakyUpstream();
  const fix = join(env.root, "fixed.sh");
  writeFileSync(fix, FIXED);
  const mirrors = join(env.root, "bench", "repos");
  const cheat = arm(
    "mirror-reader",
    `git --git-dir "$(ls -d ${mirrors}/*.git)" log --all --oneline >/dev/null\ncp ${fix} "$1/add.sh"\n`,
  );
  const honest = arm("honest", `cp ${fix} "$1/add.sh"\n`);
  const p = ports();
  await runBenchmark({ tasks: [task], arms: [cheat, honest], trials: 1, budgetUsd: 10 }, p);
  const rows = await p.store.rows();
  if (!rows.ok) throw new Error(rows.error.message);
  const by = Object.fromEntries(rows.value.map((r) => [r.armId, r]));
  expect(by.honest?.resolved).toBe(true);
  expect(by.honest?.flags).toEqual([]);
  expect(by["mirror-reader"]?.resolved).toBe(false);
  expect(by["mirror-reader"]?.note).toStartWith("voided by integrity check");
  expect(by["mirror-reader"]?.flags?.[0]).toStartWith(
    `void:cache-access: git --git-dir ${mirrors}/`,
  );
}, 60_000);

test("bench validate still reaches the gold commit through the harness", async () => {
  const task = await leakyUpstream();
  const ws = ports().workspaces;
  const dir = await ws.prepare(task, "validate");
  if (!dir.ok) throw new Error(dir.error.message);
  expect((await ws.checkout(dir.value, task.goldCommit ?? "")).ok).toBe(true);
  expect(readFileSync(join(dir.value, "add.sh"), "utf8")).toBe(FIXED);
  await ws.dispose(dir.value);
}, 60_000);
