import { afterEach, beforeEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { commitAll, gitIn, isolatedRunner } from "../../testing/git-fixture";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { GitEnvSource, normalizeRemote } from "./git-env-source";

let env: TestEnv;
let repo: string;
const runner = isolatedRunner(() => env);
const source = new GitEnvSource(runner);

beforeEach(async () => {
  env = createTestEnv();
  repo = join(env.root, "my-repo");
  mkdirSync(repo);
  await gitIn(runner, repo, "init", "-q", "-b", "main");
  mkdirSync(join(repo, ".shipwright"));
  writeFileSync(join(repo, ".shipwright", "env.json"), '{"version":1}\n');
  writeFileSync(join(repo, "bun.lock"), "lock\n");
  await commitAll(runner, repo, "base");
});
afterEach(() => env.cleanup());

test("fileAt reads a committed file and is null for one the ref does not have", async () => {
  writeFileSync(join(repo, ".shipwright", "env.json"), "edited\n");
  expect(await source.fileAt(repo, "HEAD", ".shipwright/env.json")).toEqual({
    ok: true,
    value: '{"version":1}\n',
  });
  expect(await source.fileAt(repo, "main", "missing.json")).toEqual({ ok: true, value: null });
});

test("fileAt fails on an unknown ref and refuses unsafe paths and refs", async () => {
  expect((await source.fileAt(repo, "no-such-branch", "bun.lock")).ok).toBe(false);
  expect((await source.fileAt(repo, "HEAD", "../outside")).ok).toBe(false);
  expect((await source.fileAt(repo, "--output=/tmp/x", "bun.lock")).ok).toBe(false);
});

test("readFile and digests see the working tree; missing files are null", async () => {
  writeFileSync(join(repo, "bun.lock"), "changed\n");
  expect(await source.readFile(repo, "bun.lock")).toEqual({ ok: true, value: "changed\n" });
  expect(await source.readFile(repo, "nope")).toEqual({ ok: true, value: null });
  const sha = createHash("sha256").update("changed\n").digest("hex");
  expect(await source.digests(repo, ["bun.lock", "nope/x"])).toEqual({
    ok: true,
    value: { "bun.lock": sha, "nope/x": null },
  });
  expect((await source.digests(repo, ["/etc/passwd"])).ok).toBe(false);
});

test("a symlink that leaves the checkout is refused", async () => {
  writeFileSync(join(env.root, "secret"), "s\n");
  symlinkSync(join(env.root, "secret"), join(repo, "link"));
  expect((await source.readFile(repo, "link")).ok).toBe(false);
});

test("rootEntries lists the top level", async () => {
  expect(await source.rootEntries(repo)).toEqual({
    ok: true,
    value: [".git", ".shipwright", "bun.lock"],
  });
});

test("a clone, its worktree and the original share one repo id", async () => {
  const clone = join(env.root, "clone");
  await gitIn(runner, env.root, "clone", "-q", repo, clone);
  const wt = join(env.root, "wt");
  await gitIn(runner, clone, "worktree", "add", "-q", "--detach", wt);
  const ids = await Promise.all([repo, clone, wt].map((d) => source.repoId(d)));
  const original = ids[0];
  if (!original?.ok) throw new Error("repoId failed");
  expect(original.value).toMatch(/^my-repo-[0-9a-f]{16}$/);
  expect(ids).toEqual([original, original, original]);
});

test("https and ssh remotes of one GitHub repository give the same id", async () => {
  const other = join(env.root, "other");
  await gitIn(runner, env.root, "clone", "-q", repo, other);
  await gitIn(
    runner,
    repo,
    "remote",
    "add",
    "origin",
    "https://user:tok@github.com/Acme/Widget.git",
  );
  await gitIn(runner, other, "remote", "set-url", "origin", "git@github.com:acme/widget");
  const [a, b] = [await source.repoId(repo), await source.repoId(other)];
  expect(a.ok && a.value).toMatch(/^widget-[0-9a-f]{16}$/);
  expect(b).toEqual(a);
});

test("normalizeRemote drops scheme, credentials, port, .git and case", () => {
  const forms = [
    "https://github.com/acme/widget.git",
    "https://x-access-token:abc@GitHub.com/acme/widget/",
    "ssh://git@github.com:22/acme/widget.git",
    "git@github.com:acme/widget.git",
    "git://github.com/acme/widget",
  ];
  expect(new Set(forms.map(normalizeRemote))).toEqual(new Set(["github.com/acme/widget"]));
});
