import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";

// scripts/lib/agent-exec.sh applies the permission policy to every claude call and refuses bypasses (#8614).
// A shim `claude` on PATH records its argv, so the test asserts exactly what the real CLI would receive.
const AGENT_EXEC = join(import.meta.dir, "../../../scripts/lib/agent-exec.sh");
const POLICY = join(import.meta.dir, "../../../config/agent-permissions.json");

let env: TestEnv;
let argvFile: string;

beforeEach(() => {
  env = createTestEnv();
  const bin = join(env.root, "bin");
  mkdirSync(bin, { recursive: true });
  argvFile = join(env.root, "argv.txt");
  const shim = join(bin, "claude");
  writeFileSync(shim, `#!/bin/bash\nprintf '%s\\n' "$@" > '${argvFile}'\n`);
  chmodSync(shim, 0o755);
});
afterEach(() => env.cleanup());

function run(args: string[], extraEnv: Record<string, string> = {}) {
  const bin = join(env.root, "bin");
  const result = Bun.spawnSync(["bash", AGENT_EXEC, ...args], {
    cwd: env.root,
    env: {
      PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`,
      HOME: env.home,
      ...extraEnv,
    },
    stdin: "ignore",
  });
  const argv = existsSync(argvFile)
    ? readFileSync(argvFile, "utf8").split("\n").filter(Boolean)
    : [];
  return { code: result.exitCode, stderr: result.stderr.toString(), argv };
}

describe("agent-exec permission policy (#8614, #8581)", () => {
  test("every claude call gets the policy, dontAsk and the user-only settings source", () => {
    const r = run(["claude", "-p", "hi"]);
    expect(r.code).toBe(0);
    expect(r.argv.slice(0, 8)).toEqual([
      "--settings",
      POLICY,
      "--setting-sources",
      "user",
      "--permission-mode",
      "dontAsk",
      "--permission-prompts",
      "none",
    ]);
    expect(r.argv.slice(8)).toEqual(["-p", "hi"]);
  });

  test("a path-based claude binary gets the policy too", () => {
    const r = run([join(env.root, "bin", "claude"), "-p", "x"]);
    expect(r.code).toBe(0);
    expect(r.argv).toContain("--permission-mode");
    expect(r.argv).toContain("dontAsk");
  });

  test("a wrapped claude (timeout-style) is still covered, and interactive runs skip -p-only flags", () => {
    const r = run(["env", "claude", "--model", "sonnet"]);
    expect(r.code).toBe(0);
    expect(r.argv).toContain("--permission-mode");
    expect(r.argv).not.toContain("--permission-prompts");
    expect(r.argv.slice(-2)).toEqual(["--model", "sonnet"]);
  });

  test("a caller may narrow tools with --disallowedTools", () => {
    const r = run(["claude", "-p", "audit", "--disallowedTools", "Edit,Write,NotebookEdit"]);
    expect(r.code).toBe(0);
    expect(r.argv.slice(-4)).toEqual([
      "-p",
      "audit",
      "--disallowedTools",
      "Edit,Write,NotebookEdit",
    ]);
  });

  test("refuses a bypass flag and never runs claude", () => {
    const r = run(["claude", "-p", "x", "--dangerously-skip-permissions"]);
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("refusing a permission bypass");
    expect(existsSync(argvFile)).toBe(false);
  });

  test("refuses a bypass permission mode", () => {
    const r = run(["claude", "-p", "x", "--permission-mode", "bypassPermissions"]);
    expect(r.code).toBe(1);
    expect(existsSync(argvFile)).toBe(false);
  });

  test("refuses a caller who sets the policy itself (mode, settings, sources, allow list)", () => {
    for (const flag of [
      ["--permission-mode", "acceptEdits"],
      ["--settings", "/tmp/evil.json"],
      ["--setting-sources", "project,local"],
      ["--permission-prompts", "host"],
      ["--allowedTools", "Bash"],
    ]) {
      const r = run(["claude", "-p", "x", ...flag]);
      expect(r.code).toBe(1);
      expect(r.stderr).toContain("the permission policy is set here");
    }
    expect(existsSync(argvFile)).toBe(false);
  });

  test("the operator bypass needs a terminal, so an env var alone is refused", () => {
    const r = run(["claude", "-p", "x", "--dangerously-skip-permissions"], {
      SHIPWRIGHT_OPERATOR_SKIP_PERMISSIONS: "1",
    });
    expect(r.code).toBe(1);
    expect(existsSync(argvFile)).toBe(false);
  });

  test("a non-claude command passes through unchanged", () => {
    const r = run(["sh", "-c", "exit 0"]);
    expect(r.code).toBe(0);
    expect(existsSync(argvFile)).toBe(false);
  });
});
