import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";

// scripts/lib/agent-exec.sh applies the permission policy to every claude call and refuses bypasses (#8614).
// A shim `claude` on PATH records its argv, so the test asserts exactly what the real CLI would receive.
const AGENT_EXEC = join(import.meta.dir, "../../../scripts/lib/agent-exec.sh");
const POLICY = join(import.meta.dir, "../../../config/agent-permissions.json");
const PATH_FOR_SHIM = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin";

let env: TestEnv;
let work: string;
let argvFile: string;

beforeEach(() => {
  env = createTestEnv();
  const bin = join(env.root, "bin");
  mkdirSync(bin, { recursive: true });
  work = join(env.root, "work");
  mkdirSync(work, { recursive: true });
  argvFile = join(env.root, "argv.txt");
  const shim = join(bin, "claude");
  writeFileSync(shim, `#!/bin/bash\nprintf '%s\\0' "$@" > '${argvFile}'\n`);
  chmodSync(shim, 0o755);
});
afterEach(() => env.cleanup());

function run(args: string[], extraEnv: Record<string, string> = {}, cwd = work) {
  const bin = join(env.root, "bin");
  const result = Bun.spawnSync(["bash", AGENT_EXEC, ...args], {
    cwd,
    env: { PATH: `${bin}:${PATH_FOR_SHIM}`, HOME: env.home, ...extraEnv },
    stdin: "ignore",
  });
  const argv = existsSync(argvFile)
    ? readFileSync(argvFile, "utf8")
        .split("\0")
        .filter((a) => a !== "")
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

  test("a wrapped claude (env-style) is refused: claude must be the command word (#8673)", () => {
    const r = run(["env", "claude", "--model", "sonnet"]);
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("only claude is launched through this wrapper");
    expect(existsSync(argvFile)).toBe(false);
  });

  test("interactive runs skip -p-only flags", () => {
    const r = run(["claude", "--model", "sonnet"]);
    expect(r.code).toBe(0);
    expect(r.argv).toContain("--permission-mode");
    expect(r.argv).not.toContain("--permission-prompts");
    expect(r.argv.slice(-2)).toEqual(["--model", "sonnet"]);
  });

  test("the command gate: a claude word later in argv does not pass (#8673)", () => {
    const r = run(["/bin/echo", "NOT-CLAUDE", "claude"]);
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("only claude is launched through this wrapper");
    expect(existsSync(argvFile)).toBe(false);
  });

  test("the command gate: a timeout prefix is allowed, and the policy goes right after claude", () => {
    // macOS has no timeout(1) by default: a shim drops the duration and runs the rest.
    const shim = join(env.root, "bin", "timeout");
    writeFileSync(shim, '#!/bin/bash\nshift\nexec "$@"\n');
    chmodSync(shim, 0o755);
    const r = run(["timeout", "5", "claude", "-p", "hi"]);
    expect(r.code).toBe(0);
    expect(r.argv.slice(0, 2)).toEqual(["--settings", POLICY]);
    expect(r.argv.slice(-2)).toEqual(["-p", "hi"]);
  });

  test("the command gate: a timeout prefix must be followed by a duration and then claude", () => {
    expect(run(["timeout", "claude", "-p", "hi"]).code).toBe(1);
    expect(run(["timeout", "5", "/bin/echo", "claude"]).code).toBe(1);
    expect(run(["gtimeout", "/bin/echo", "NOT-CLAUDE", "claude"]).code).toBe(1);
  });

  test("project memory is capped at 64 KiB with a marker, never passed whole", () => {
    writeFileSync(join(work, "CLAUDE.md"), "x".repeat(200 * 1024));
    const r = run(["claude", "-p", "hi"]);
    expect(r.code).toBe(0);
    const memory = r.argv[r.argv.indexOf("--append-system-prompt") + 1] ?? "";
    expect(Buffer.byteLength(memory)).toBeLessThanOrEqual(65536);
    expect(memory).toContain("project memory truncated at 64 KiB");
  });

  test("a multi-byte project memory is cut at the cap without splitting a character", () => {
    writeFileSync(join(work, "CLAUDE.md"), "é".repeat(100 * 1024));
    const r = run(["claude", "-p", "hi"]);
    expect(r.code).toBe(0);
    const memory = r.argv[r.argv.indexOf("--append-system-prompt") + 1] ?? "";
    expect(Buffer.byteLength(memory)).toBeLessThanOrEqual(65536);
    expect(memory).not.toContain("�");
  });

  test("SW_MEMORY_REF reads the project memory from that git ref, not the working tree (#8673)", () => {
    const git = (...args: string[]) =>
      Bun.spawnSync(["git", "-c", "commit.gpgsign=false", ...args], {
        cwd: work,
        env: {
          PATH: PATH_FOR_SHIM,
          HOME: env.home,
          GIT_AUTHOR_NAME: "t",
          GIT_AUTHOR_EMAIL: "t@example.invalid",
          GIT_COMMITTER_NAME: "t",
          GIT_COMMITTER_EMAIL: "t@example.invalid",
        },
      });
    git("init", "-q");
    writeFileSync(join(work, "CLAUDE.md"), "BASE RULE");
    git("add", "CLAUDE.md");
    git("commit", "-q", "-m", "base");
    writeFileSync(join(work, "CLAUDE.md"), "BUILDER EDIT");
    const r = run(["claude", "-p", "audit"], { SW_MEMORY_REF: "HEAD" });
    expect(r.code).toBe(0);
    const memory = r.argv[r.argv.indexOf("--append-system-prompt") + 1] ?? "";
    expect(memory).toContain("BASE RULE");
    expect(memory).not.toContain("BUILDER EDIT");
  });

  test("SW_MEMORY_REF that names no commit is refused, not silently replaced by the working tree", () => {
    const r = run(["claude", "-p", "audit"], { SW_MEMORY_REF: "no-such-ref" });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("SW_MEMORY_REF does not name a commit");
    expect(existsSync(argvFile)).toBe(false);
  });

  test("a caller may narrow tools with --disallowedTools=, and the prompt reaches claude", () => {
    const r = run(["claude", "-p", "audit", "--disallowedTools=Edit,Write,NotebookEdit"]);
    expect(r.code).toBe(0);
    expect(r.argv.slice(-3)).toEqual(["-p", "audit", "--disallowedTools=Edit,Write,NotebookEdit"]);
  });

  test("project memory (CLAUDE.md, AGENTS.md, .claude/rules) goes through --append-system-prompt", () => {
    writeFileSync(join(work, "CLAUDE.md"), "PROJECT RULE ONE");
    writeFileSync(join(work, "AGENTS.md"), "AGENT GUIDE");
    mkdirSync(join(work, ".claude", "rules"), { recursive: true });
    writeFileSync(join(work, ".claude", "rules", "bash.md"), "BASH RULE");
    const r = run(["claude", "-p", "hi"]);
    expect(r.code).toBe(0);
    const i = r.argv.indexOf("--append-system-prompt");
    expect(i).toBeGreaterThan(-1);
    const memory = r.argv[i + 1] ?? "";
    expect(memory).toContain("PROJECT RULE ONE");
    expect(memory).toContain("AGENT GUIDE");
    expect(memory).toContain("BASH RULE");
    expect(r.argv.slice(-1)).toEqual(["hi"]);
  });

  test("with no project memory there is no --append-system-prompt", () => {
    const r = run(["claude", "-p", "hi"]);
    expect(r.argv).not.toContain("--append-system-prompt");
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

  test("refuses any launcher other than claude (F9: nothing runs outside the policy)", () => {
    for (const cmd of [
      ["sh", "-c", "exit 0"],
      ["claude-code", "-p", "x"],
      ["env", "bash"],
    ]) {
      const r = run(cmd);
      expect(r.code).toBe(1);
      expect(r.stderr).toContain("only claude is launched");
    }
  });

  test("the operator bypass needs a terminal, so an env var alone is refused", () => {
    const r = run(["claude", "-p", "x", "--dangerously-skip-permissions"], {
      SHIPWRIGHT_OPERATOR_SKIP_PERMISSIONS: "1",
    });
    expect(r.code).toBe(1);
    expect(existsSync(argvFile)).toBe(false);
  });

  test("SW_AGENT_POLICY may point to a snapshot outside the working tree", () => {
    const snapshot = join(env.root, "runner-temp", "agent-permissions.json");
    mkdirSync(join(env.root, "runner-temp"), { recursive: true });
    writeFileSync(snapshot, readFileSync(POLICY, "utf8"));
    const r = run(["claude", "-p", "hi"], { SW_AGENT_POLICY: snapshot });
    expect(r.code).toBe(0);
    expect(r.argv.slice(0, 2)).toEqual(["--settings", snapshot]);
  });

  test("in CI, a policy inside the agent's working tree is refused", () => {
    const inTree = join(work, "agent-permissions.json");
    writeFileSync(inTree, readFileSync(POLICY, "utf8"));
    const r = run(["claude", "-p", "hi"], { CI: "true", SW_AGENT_POLICY: inTree });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("must not live in the agent's working tree");
    expect(existsSync(argvFile)).toBe(false);
  });

  test("in CI, the default policy in the checkout is refused too (the pipeline must snapshot it)", () => {
    // The default path is <repo>/config, which is the agent's tree when the repo is the working directory.
    // Run from the repo itself so the default is inside the working tree.
    const repo = join(import.meta.dir, "../../..");
    const r = run(["claude", "-p", "hi"], { CI: "true" }, repo);
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("must not live in the agent's working tree");
  });

  test("a nested agent may not choose its own policy", () => {
    const own = join(env.root, "own.json");
    writeFileSync(own, "{}");
    const r = run(["claude", "-p", "x"], {
      SHIPWRIGHT_IN_TEST_GATE: "1",
      CLAUDE_AGENT_SDK_CLIENT_APP: "shipwright",
      SW_AGENT_POLICY: own,
    });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("refusing SW_AGENT_POLICY inside an agent run");
  });
});
