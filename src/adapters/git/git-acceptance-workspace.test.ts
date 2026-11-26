import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { lockTests, materialize, verifyGreen, verifyRed } from "../../contexts/planning";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { BunProcessRunner } from "../process/bun-process-runner";
import { TestGateExecutor } from "../process/test-gate-executor";
import { NodeArtifactStore } from "../state/node-artifact-store";
import { GitAcceptanceWorkspace } from "./git-acceptance-workspace";

const GATE = join(import.meta.dir, "..", "..", "..", "scripts", "lib", "test-gate-exec.sh");
const PATH = "tests/slug.test.ts";
const TEST_SRC = `import { expect, test } from "bun:test";
import { slugify } from "../src/slug";
test("AC-1: lowercases and joins words with dashes", () => {
  expect(slugify("Hello World")).toBe("hello-world");
});
`;
const ANSWER = `\`\`\`acceptance.json
{"criteria":[{"id":"AC-1","text":"slugify lowercases and dashes words"}],"tests":[{"path":"${PATH}","criteria":["AC-1"]}]}
\`\`\`
\`\`\`${PATH}
${TEST_SRC}\`\`\``;

let env: TestEnv;
let repo: string;
const git = (...args: string[]) => {
  const r = Bun.spawnSync(
    ["git", "-c", "user.name=t", "-c", "user.email=t@e", "-c", "commit.gpgsign=false", ...args],
    { cwd: repo },
  );
  if (r.exitCode !== 0) throw new Error(r.stderr.toString());
};

beforeEach(() => {
  env = createTestEnv();
  repo = join(env.root, "repo");
  mkdirSync(join(repo, "src"), { recursive: true });
  writeFileSync(join(repo, "src", "other.ts"), "export const x = 1;\n");
  git("init", "-q");
  git("add", "-A");
  git("commit", "-qm", "init");
});
afterEach(() => env.cleanup());

function ports() {
  const runner = new BunProcessRunner();
  return {
    ws: new GitAcceptanceWorkspace(runner, repo),
    exec: new TestGateExecutor(runner, GATE, repo),
    artifacts: new NodeArtifactStore(),
  };
}

describe("acceptance tests on a real repository with bun test", () => {
  test("red for the missing feature, locked, then green once implemented; tampering is undone and blocks", async () => {
    const p = ports();
    const manifestPath = join(env.root, "artifacts", "acceptance.json");
    const lockPath = join(env.root, "artifacts", "acceptance-lock.json");
    const opts = { manifestPath, testCmd: "bun test", timeoutMs: 60_000 };
    expect((await materialize(ANSWER, manifestPath, p)).ok).toBe(true);

    const red = await verifyRed(opts, p);
    expect(red).toMatchObject({ ok: true });
    if (red.kind === "tests") expect(red.runs[0]?.verdict.reason).toBe("missing_feature");

    git("add", "--", PATH);
    git("commit", "-qm", "test: acceptance");
    expect((await lockTests({ ...opts, lockPath }, p)).ok).toBe(true);

    writeFileSync(
      join(repo, "src", "slug.ts"),
      'export const slugify = (s: string) => s.toLowerCase().split(" ").join("-");\n',
    );
    const green = await verifyGreen({ lockPath, timeoutMs: 60_000, integrity: "enforce" }, p);
    expect(green).toMatchObject({ ok: true, violations: [] });

    // The agent "fixes" the test instead: the gate restores the original and reports it.
    writeFileSync(join(repo, "src", "slug.ts"), "export const slugify = (s: string) => s;\n");
    writeFileSync(join(repo, PATH), TEST_SRC.replace('toBe("hello-world")', "toBeDefined()"));
    const tampered = await verifyGreen({ lockPath, timeoutMs: 60_000, integrity: "enforce" }, p);
    expect(tampered.ok).toBe(false);
    expect(tampered.restored).toEqual([PATH]);
    expect(tampered.violations.map((v) => v.rule)).toContain("acceptance_test_changed");
    expect(readFileSync(join(repo, PATH), "utf8")).toBe(TEST_SRC);
  }, 120_000);

  test("a test with a syntax error is rejected as not red for the right reason", async () => {
    const p = ports();
    const manifestPath = join(env.root, "m.json");
    const broken = ANSWER.replace('toBe("hello-world");', 'toBe("hello-world";');
    expect((await materialize(broken, manifestPath, p)).ok).toBe(true);
    const red = await verifyRed({ manifestPath, testCmd: "bun test", timeoutMs: 60_000 }, p);
    expect(red.ok).toBe(false);
    if (red.kind === "tests") expect(red.runs[0]?.verdict.reason).toBe("test_broken");
  }, 120_000);

  test("writes stay inside the repository and never overwrite", async () => {
    const ws = ports().ws;
    expect((await ws.writeText("../escape.test.ts", "x")).ok).toBe(false);
    expect((await ws.writeText("src/other.ts", "y")).ok).toBe(false);
    expect(readFileSync(join(repo, "src", "other.ts"), "utf8")).toBe("export const x = 1;\n");
  });
});
