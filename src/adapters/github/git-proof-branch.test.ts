import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { idempotencyKey } from "../../shared/kernel/durability";
import type { ProcessRunner } from "../../shared/kernel/ports";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { BunProcessRunner } from "../process/bun-process-runner";
import { GitProofBranch, githubRepoOf, PROOF_BRANCH } from "./git-proof-branch";

// Real git against a bare repository that stands in for GitHub: `url.<bare>.insteadOf` sends the
// github.com remote there, so the push, the fetch and the reconcile are git's own behaviour.
let env: TestEnv;
let repo: string;
let bare: string;
let artifacts: string;
const real = new BunProcessRunner();
const PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";
const gitEnv = () => ({
  PATH,
  HOME: env.home,
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_CONFIG_GLOBAL: "/dev/null",
});
const runner: ProcessRunner = {
  run: (req) => real.run({ ...req, env: { ...gitEnv(), ...(req.env ?? {}) } }),
};

async function git(cwd: string, ...args: string[]): Promise<string> {
  const r = await runner.run({ argv: ["git", "-C", cwd, ...args], timeoutMs: 30_000 });
  if (r.exitCode !== 0) throw new Error(r.stderr);
  return r.stdout.trim();
}

beforeEach(async () => {
  env = createTestEnv();
  repo = join(env.root, "repo");
  bare = join(env.root, "bare.git");
  artifacts = join(env.root, "out");
  mkdirSync(repo);
  mkdirSync(join(artifacts, "web"), { recursive: true });
  writeFileSync(join(artifacts, "web", "1-home.png"), "png-bytes");
  writeFileSync(join(artifacts, "web", "server.log"), "ready");
  await git(env.root, "init", "-q", "--bare", bare);
  await git(repo, "init", "-q", "-b", "main");
  await git(repo, "remote", "add", "origin", "https://github.com/acme/app.git");
  await git(repo, "config", `url.${bare}.insteadOf`, "https://github.com/acme/app.git");
  writeFileSync(join(repo, "a.txt"), "a\n");
  await git(repo, "add", "a.txt");
  await git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base");
});
afterEach(() => env.cleanup());

const upload = (prefix = "feat-x/abc") => ({
  repoRoot: repo,
  dir: artifacts,
  files: ["web/1-home.png", "web/server.log"],
  prefix,
});

test("GitHub remote URLs give owner/repo; anything else is refused", () => {
  expect(githubRepoOf("https://github.com/acme/app.git")).toBe("acme/app");
  expect(githubRepoOf("https://x-access-token:t@github.com/acme/app")).toBe("acme/app");
  expect(githubRepoOf("git@github.com:acme/app.git")).toBe("acme/app");
  expect(githubRepoOf("ssh://git@github.com/acme/app.git")).toBe("acme/app");
  expect(githubRepoOf("https://gitlab.com/acme/app.git")).toBeNull();
  expect(githubRepoOf("https://github.com.evil.io/acme/app")).toBeNull();
});

test("publishes a commit holding only the run's files, without touching the checkout", async () => {
  const writer = new GitProofBranch(runner, gitEnv());
  const r = await writer.publishProof(idempotencyKey("proof", "1"), upload());
  expect(r.ok).toBe(true);
  if (!r.ok) return;
  expect(r.value.action).toBe("created");
  expect(r.value.baseUrl).toBe(`https://github.com/acme/app/raw/${r.value.commit}/feat-x/abc/`);
  expect(await git(bare, "rev-parse", `refs/heads/${PROOF_BRANCH}`)).toBe(r.value.commit);
  expect(await git(bare, "ls-tree", "-r", "--name-only", r.value.commit)).toBe(
    "feat-x/abc/web/1-home.png\nfeat-x/abc/web/server.log",
  );
  expect(await git(bare, "show", `${r.value.commit}:feat-x/abc/web/server.log`)).toBe("ready");
  expect(await git(repo, "status", "--porcelain")).toBe("");
  expect(await git(repo, "rev-parse", "--abbrev-ref", "HEAD")).toBe("main");
});

test("the same key reuses the commit; a new run stacks on the tip with a small tree", async () => {
  const writer = new GitProofBranch(runner, gitEnv());
  const first = await writer.publishProof(idempotencyKey("proof", "1"), upload());
  const again = await writer.publishProof(idempotencyKey("proof", "1"), upload());
  expect(again.ok && again.value.action).toBe("unchanged");
  expect(again.ok && first.ok && again.value.commit === first.value.commit).toBe(true);
  const second = await writer.publishProof(idempotencyKey("proof", "2"), upload("feat-y/def"));
  expect(second.ok).toBe(true);
  if (!second.ok || !first.ok) return;
  expect(await git(bare, "rev-parse", `${second.value.commit}^`)).toBe(first.value.commit);
  expect(await git(bare, "ls-tree", "--name-only", second.value.commit)).toBe("feat-y");
});

test("a non-GitHub origin is refused before anything is written", async () => {
  await git(repo, "remote", "set-url", "origin", "https://gitlab.com/acme/app.git");
  const r = await new GitProofBranch(runner, gitEnv()).publishProof(idempotencyKey("p"), upload());
  expect(r.ok).toBe(false);
});
