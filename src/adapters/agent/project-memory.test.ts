import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { capMemory, PROJECT_MEMORY_CAP_BYTES, readProjectMemory } from "./project-memory";

let env: TestEnv;
let repo: string;

beforeEach(() => {
  env = createTestEnv();
  repo = join(env.root, "repo");
  mkdirSync(repo, { recursive: true });
});
afterEach(() => env.cleanup());

function git(...args: string[]): void {
  const r = Bun.spawnSync(["git", "-c", "commit.gpgsign=false", ...args], {
    cwd: repo,
    env: {
      PATH: "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
      HOME: env.home,
      GIT_AUTHOR_NAME: "t",
      GIT_AUTHOR_EMAIL: "t@example.invalid",
      GIT_COMMITTER_NAME: "t",
      GIT_COMMITTER_EMAIL: "t@example.invalid",
    },
  });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr.toString()}`);
}

describe("project memory (#8673)", () => {
  test("the working tree is the source when no memoryRef is given", async () => {
    writeFileSync(join(repo, "CLAUDE.md"), "TREE RULE");
    const memory = await readProjectMemory(repo);
    expect(memory).toContain("TREE RULE");
  });

  test("a memoryRef reads the files at that commit, so working-tree edits are ignored", async () => {
    git("init", "-q");
    mkdirSync(join(repo, ".claude", "rules"), { recursive: true });
    writeFileSync(join(repo, "CLAUDE.md"), "BASE RULE");
    writeFileSync(join(repo, ".claude", "rules", "bash.md"), "BASE BASH RULE");
    git("add", "-A");
    git("commit", "-q", "-m", "base");
    writeFileSync(join(repo, "CLAUDE.md"), "BUILDER EDIT");
    writeFileSync(join(repo, ".claude", "rules", "evil.md"), "BUILDER RULE");

    const memory = await readProjectMemory(repo, "HEAD");
    expect(memory).toContain("BASE RULE");
    expect(memory).toContain("BASE BASH RULE");
    expect(memory).not.toContain("BUILDER EDIT");
    expect(memory).not.toContain("BUILDER RULE");
  });

  test("a memoryRef that names no commit throws instead of falling back to the tree", async () => {
    git("init", "-q");
    writeFileSync(join(repo, "CLAUDE.md"), "TREE RULE");
    await expect(readProjectMemory(repo, "no-such-ref")).rejects.toThrow("does not name a commit");
  });

  test("a memoryRef reads top-level rules only, like the working tree", async () => {
    git("init", "-q");
    mkdirSync(join(repo, ".claude", "rules", "sub"), { recursive: true });
    writeFileSync(join(repo, ".claude", "rules", "top.md"), "TOP RULE");
    writeFileSync(join(repo, ".claude", "rules", "sub", "nested.md"), "NESTED RULE");
    git("add", "-A");
    git("commit", "-q", "-m", "rules");
    const memory = await readProjectMemory(repo, "HEAD");
    expect(memory).toContain("TOP RULE");
    expect(memory).not.toContain("NESTED RULE");
  });

  test("a multi-byte cut never exceeds the cap", () => {
    const capped = capMemory("😀".repeat(PROJECT_MEMORY_CAP_BYTES));
    expect(Buffer.byteLength(capped)).toBeLessThanOrEqual(PROJECT_MEMORY_CAP_BYTES);
    expect(capped).toContain("project memory truncated at 64 KiB");
  });

  test("memory is capped at 64 KiB with a marker", () => {
    const big = "x".repeat(PROJECT_MEMORY_CAP_BYTES * 3);
    const capped = capMemory(big);
    expect(Buffer.byteLength(capped)).toBeLessThanOrEqual(PROJECT_MEMORY_CAP_BYTES);
    expect(capped).toContain("project memory truncated at 64 KiB");
    expect(capMemory("short")).toBe("short");
  });
});
