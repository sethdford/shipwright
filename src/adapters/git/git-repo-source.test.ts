import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { GitRepoSource, parseAuthorship } from "./git-repo-source";

let env: TestEnv | undefined;
afterEach(() => env?.cleanup());

describe("GitRepoSource", () => {
  test("lists tracked and untracked files with their sizes, skipping unsafe and deleted paths", async () => {
    env = createTestEnv();
    mkdirSync(join(env.root, "src"));
    writeFileSync(join(env.root, "src/a.ts"), "export const a = 1;\n");
    const runner = new FakeProcessRunner([
      {
        prefix: ["git", "ls-files"],
        result: { exitCode: 0, stdout: "src/a.ts\0gone.ts\0../x.ts\0", stderr: "" },
      },
    ]);
    const listed = await new GitRepoSource(runner).list(env.root);
    expect(listed.ok && listed.value.map((s) => [s.path, s.size])).toEqual([["src/a.ts", 20]]);
    expect(runner.calls[0]?.argv).toEqual([
      "git",
      "ls-files",
      "-z",
      "--cached",
      "--others",
      "--exclude-standard",
    ]);
    expect(runner.calls[0]?.timeoutMs).toBeGreaterThan(0);
  });

  test("reads only repository paths", async () => {
    env = createTestEnv();
    writeFileSync(join(env.root, "x.sh"), "echo hi\n");
    const src = new GitRepoSource(new FakeProcessRunner([]));
    expect(await src.read(env.root, "x.sh")).toEqual({ ok: true, value: "echo hi\n" });
    expect((await src.read(env.root, "../etc/passwd")).ok).toBe(false);
    expect((await src.read(env.root, "missing.ts")).ok).toBe(false);
  });

  test("head is empty outside history; a failing git list is an error", async () => {
    const runner = new FakeProcessRunner([
      { prefix: ["git", "rev-parse"], result: { exitCode: 1, stdout: "", stderr: "" } },
      {
        prefix: ["git", "ls-files"],
        result: { exitCode: 128, stdout: "", stderr: "fatal: not a git repository" },
      },
    ]);
    const src = new GitRepoSource(runner);
    expect(await src.head("/r")).toBe("");
    const listed = await src.list("/r");
    expect(!listed.ok && listed.error.kind).toBe("not_found");
  });

  test("authorship counts commits per author and path, most active first", () => {
    const out =
      "\x1eAda\x1f2026-11-20\n\nsrc/a.ts\nsrc/b.ts\n\x1eBob\x1f2026-11-21\n\nsrc/a.ts\n\x1eAda\x1f2026-11-01\n\nsrc/a.ts\n";
    expect(parseAuthorship(out)["src/a.ts"]).toEqual([
      { name: "Ada", commits: 2, last: "2026-11-20" },
      { name: "Bob", commits: 1, last: "2026-11-21" },
    ]);
  });
});
