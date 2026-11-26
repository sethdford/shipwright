import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ProcessRunner } from "../../shared/kernel/ports";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { BunProcessRunner } from "../process/bun-process-runner";
import { GitWorkspaces } from "./git-workspaces";

// A real repository in a temp dir: worktrees, commits and fast-forwards are git behaviour, so
// they are tested against git, not a script of it.
let env: TestEnv;
let repo: string;
const real = new BunProcessRunner();
const PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";
// Every git call, the adapter's included, sees only the test HOME and no user or system config.
const runner: ProcessRunner = {
  run: (req) =>
    real.run({
      ...req,
      env: { PATH, HOME: env.home, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" },
    }),
};

async function git(cwd: string, ...args: string[]): Promise<string> {
  const r = await runner.run({ argv: ["git", ...args], cwd, timeoutMs: 30_000 });
  if (r.exitCode !== 0) throw new Error(r.stderr);
  return r.stdout.trim();
}

beforeEach(async () => {
  env = createTestEnv();
  repo = join(env.root, "repo");
  mkdirSync(repo);
  await git(repo, "init", "-q", "-b", "main");
  writeFileSync(join(repo, "a.ts"), "export const a = 1;\n");
  await git(repo, "add", "a.ts");
  await git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base");
});
afterEach(() => env.cleanup());

const workspaces = () => new GitWorkspaces(runner, repo, join(env.stateDir, "tournaments", "run1"));

test("an attempt's changes are committed in its own worktree, outside the repository", async () => {
  const ws = workspaces();
  const base = await ws.baseSha();
  if (!base.ok) throw new Error(base.error.message);
  const w = await ws.create("a1", base.value);
  if (!w.ok) throw new Error(w.error.message);
  expect(w.value.path.startsWith(env.stateDir)).toBe(true);
  writeFileSync(join(w.value.path, "a.ts"), "export const a = 2;\n");
  writeFileSync(join(w.value.path, "a.test.ts"), "test\n");
  const snap = await ws.snapshot(w.value, base.value);
  if (!snap.ok) throw new Error(snap.error.message);
  expect([...snap.value.files].sort()).toEqual(["a.test.ts", "a.ts"]);
  expect(snap.value.patch).toContain("+export const a = 2;");
  expect(await git(repo, "status", "--porcelain")).toBe("");
  expect(await git(w.value.path, "log", "-1", "--format=%an")).toBe("shipwright");
});

test("an attempt that changed nothing has an empty patch", async () => {
  const ws = workspaces();
  const base = (await ws.baseSha()) as { ok: true; value: string };
  const w = await ws.create("a2", base.value);
  if (!w.ok) throw new Error(w.error.message);
  const snap = await ws.snapshot(w.value, base.value);
  expect(snap.ok && snap.value.patch).toBe("");
  expect(snap.ok && snap.value.sha).toBe(base.value);
});

test("another attempt's tests can be overlaid and then reset away", async () => {
  const ws = workspaces();
  const base = (await ws.baseSha()) as { ok: true; value: string };
  const [w1, w2] = [await ws.create("a1", base.value), await ws.create("a2", base.value)];
  if (!w1.ok || !w2.ok) throw new Error("create failed");
  writeFileSync(join(w2.value.path, "b.test.ts"), "from a2\n");
  const s1 = await ws.snapshot(w1.value, base.value);
  const s2 = await ws.snapshot(w2.value, base.value);
  if (!s1.ok || !s2.ok) throw new Error("snapshot failed");
  expect((await ws.overlay(w1.value, s2.value.sha, ["b.test.ts"])).ok).toBe(true);
  expect(readFileSync(join(w1.value.path, "b.test.ts"), "utf8")).toBe("from a2\n");
  writeFileSync(join(w1.value.path, "junk.txt"), "left by a test run\n");
  expect((await ws.reset(w1.value, s1.value.sha)).ok).toBe(true);
  expect(existsSync(join(w1.value.path, "b.test.ts"))).toBe(false);
  expect(existsSync(join(w1.value.path, "junk.txt"))).toBe(false);
});

test("the winner fast-forwards the branch, and removal is idempotent", async () => {
  const ws = workspaces();
  const base = (await ws.baseSha()) as { ok: true; value: string };
  const w = await ws.create("a1", base.value);
  if (!w.ok) throw new Error(w.error.message);
  writeFileSync(join(w.value.path, "a.ts"), "export const a = 3;\n");
  const snap = await ws.snapshot(w.value, base.value);
  if (!snap.ok) throw new Error(snap.error.message);
  expect((await ws.adopt(snap.value.sha)).ok).toBe(true);
  expect(await git(repo, "rev-parse", "HEAD")).toBe(snap.value.sha);
  expect(readFileSync(join(repo, "a.ts"), "utf8")).toBe("export const a = 3;\n");
  expect((await ws.remove(w.value)).ok).toBe(true);
  expect((await ws.remove(w.value)).ok).toBe(true);
  expect(existsSync(w.value.path)).toBe(false);
  expect(await git(repo, "worktree", "list", "--porcelain")).not.toContain(w.value.path);
});

test("adopting fails when the branch has moved on", async () => {
  const ws = workspaces();
  const base = (await ws.baseSha()) as { ok: true; value: string };
  const w = await ws.create("a1", base.value);
  if (!w.ok) throw new Error(w.error.message);
  writeFileSync(join(w.value.path, "a.ts"), "export const a = 4;\n");
  const snap = await ws.snapshot(w.value, base.value);
  if (!snap.ok) throw new Error(snap.error.message);
  writeFileSync(join(repo, "c.ts"), "x\n");
  await git(repo, "add", "c.ts");
  await git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "moved");
  expect((await ws.adopt(snap.value.sha)).ok).toBe(false);
});

test("labels and shas that are not plain are refused before git runs", async () => {
  const ws = workspaces();
  expect((await ws.create("../escape", "a".repeat(40))).ok).toBe(false);
  expect((await ws.create("a1", "--upload-pack=x")).ok).toBe(false);
});
