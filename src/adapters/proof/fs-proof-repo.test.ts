import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { FsProofRepo } from "./fs-proof-repo";

let env: TestEnv;
beforeEach(() => {
  env = createTestEnv();
  writeFileSync(join(env.root, "package.json"), '{"scripts":{"dev":"vite"}}');
  writeFileSync(join(env.root, "pnpm-lock.yaml"), "");
  mkdirSync(join(env.root, "cmd", "api"), { recursive: true });
  writeFileSync(join(env.root, "cmd", "api", "main.go"), "package main");
  mkdirSync(join(env.root, ".shipwright"));
  writeFileSync(join(env.root, ".shipwright", "proof.json"), '{"enabled":false}');
});
afterEach(() => env.cleanup());

const git = (stdout: string, exitCode = 0) => ({ exitCode, stdout, stderr: "" });

test("reads root facts and proof.json", async () => {
  const repo = new FsProofRepo(new FakeProcessRunner([]), env.root);
  const facts = await repo.facts();
  expect(facts.ok && facts.value).toEqual({
    packageJson: '{"scripts":{"dev":"vite"}}',
    markers: ["pnpm-lock.yaml"],
    cargoToml: null,
    goMains: ["api"],
  });
  const config = await repo.config();
  expect(config.ok && config.value).toBe('{"enabled":false}');
});

test("changed files: committed, uncommitted and untracked, once each", async () => {
  const runner = new FakeProcessRunner([
    {
      prefix: ["git", "-C", env.root, "diff", "--name-only", "origin/main...HEAD"],
      result: git("app/page.tsx\nlib/a.ts\n"),
    },
    { prefix: ["git", "-C", env.root, "diff", "--name-only", "HEAD"], result: git("lib/a.ts\n") },
    { prefix: ["git", "-C", env.root, "ls-files"], result: git("app/new/page.tsx\n") },
  ]);
  const r = await new FsProofRepo(runner, env.root).changedFiles("origin/main");
  expect(r.ok && r.value).toEqual(["app/page.tsx", "lib/a.ts", "app/new/page.tsx"]);
});

test("a bad base ref is refused before git runs; a failed diff is an error", async () => {
  const none = new FsProofRepo(new FakeProcessRunner([]), env.root);
  expect((await none.changedFiles("--output=/tmp/x")).ok).toBe(false);
  const runner = new FakeProcessRunner([{ prefix: ["git"], result: git("", 128) }]);
  expect((await new FsProofRepo(runner, env.root).changedFiles("origin/main")).ok).toBe(false);
});
