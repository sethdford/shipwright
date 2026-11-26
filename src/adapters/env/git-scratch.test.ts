import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { commitAll, gitIn, isolatedRunner } from "../../testing/git-fixture";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { GitScratch } from "./git-scratch";

let env: TestEnv;
let repo: string;
const runner = isolatedRunner(() => env);
const scratch = () => new GitScratch(runner, join(env.stateDir, "env-scratch"));

beforeEach(async () => {
  env = createTestEnv();
  repo = join(env.root, "repo");
  mkdirSync(repo);
  await gitIn(runner, repo, "init", "-q", "-b", "main");
  writeFileSync(join(repo, "a.txt"), "one\n");
  await commitAll(runner, repo, "one");
  await gitIn(runner, repo, "tag", "v1");
  writeFileSync(join(repo, "a.txt"), "two\n");
  await commitAll(runner, repo, "two");
});
afterEach(() => env.cleanup());

test("clone checks out the ref outside the repository, with no remote", async () => {
  const s = scratch();
  const dir = await s.clone(repo, "v1");
  if (!dir.ok) throw new Error(dir.error.message);
  expect(dir.value.startsWith(realpathSync(join(env.stateDir, "env-scratch")))).toBe(true);
  // The test sandbox's layout, so env-exec.sh can jail an unreviewed recipe in it.
  expect(basename(dir.value)).toBe("repo");
  expect(basename(dirname(dir.value)).startsWith("sw-test-sandbox.")).toBe(true);
  expect(existsSync(join(dirname(dir.value), "tmp"))).toBe(true);
  expect(readFileSync(join(dir.value, "a.txt"), "utf8")).toBe("one\n");
  expect(await gitIn(runner, dir.value, "remote")).toBe("");
  expect(await gitIn(runner, dir.value, "rev-parse", "HEAD")).toBe(
    await gitIn(runner, repo, "rev-parse", "v1"),
  );
  expect((await s.remove(dir.value)).ok).toBe(true);
  expect(existsSync(dirname(dir.value))).toBe(false);
  expect((await s.remove(dir.value)).ok).toBe(true);
});

test("clone of an unknown ref fails and leaves nothing behind", async () => {
  const r = await scratch().clone(repo, "nope");
  expect(r.ok).toBe(false);
});

test("write creates parents and refuses unsafe paths", async () => {
  const s = scratch();
  expect((await s.write(repo, ".shipwright/env.json", "{}\n")).ok).toBe(true);
  expect(readFileSync(join(repo, ".shipwright", "env.json"), "utf8")).toBe("{}\n");
  expect((await s.write(repo, "../escape", "x")).ok).toBe(false);
  expect((await s.write(repo, ".git/config", "x")).ok).toBe(false);
});

test("remove refuses directories outside the scratch base", async () => {
  expect((await scratch().remove(repo)).ok).toBe(false);
  expect(existsSync(repo)).toBe(true);
});
