import { expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BunProcessRunner } from "../../src/adapters/process/bun-process-runner";
import type { ProgressEntry } from "./progress";
import {
  buildSandbox,
  failClosedShim,
  gitSnapshot,
  killSandboxTmux,
  parityEnv,
  planStubs,
  socketsIn,
  stubFor,
  suiteArgv,
  sweepStragglers,
  tmuxKillArgv,
} from "./sandbox";

const entry = (command: string, status: ProgressEntry["status"]): ProgressEntry => ({
  command,
  aliases: [],
  script: `sw-${command}.sh`,
  context: "platform",
  parity: `scripts/sw-${command}-test.sh`,
  status,
});

function tmp(): string {
  return mkdtempSync(join(tmpdir(), "sw-parity-"));
}

test("stubFor execs the TypeScript CLI for the command", () => {
  expect(stubFor(entry("hello", "porting"), "/repo")).toBe(
    '#!/usr/bin/env bash\nexec bun "/repo/src/cli.ts" hello "$@"\n',
  );
});

test("planStubs covers only entries past 'bash'", () => {
  const plan = planStubs(
    [
      entry("a", "bash"),
      entry("b", "porting"),
      entry("c", "parity-green"),
      entry("d", "bash-deleted"),
    ],
    "/repo",
  );
  expect(plan.map((p) => p.script)).toEqual(["sw-b.sh", "sw-c.sh", "sw-d.sh"]);
  expect(plan[0]?.content).toContain('cli.ts" b ');
});

test("parityEnv is hermetic and prepends the fail-closed shim dir", () => {
  expect(parityEnv("/sbx", { PATH: "/bin", GITHUB_TOKEN: "secret" })).toEqual({
    PATH: "/sbx/bin:/bin",
    HOME: "/sbx/home",
    TMUX_TMPDIR: "/sbx",
    TMPDIR: "/sbx/tmp",
    TERM: "dumb",
    LC_ALL: "C",
    TZ: "UTC",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_TERMINAL_PROMPT: "0",
    NO_GITHUB: "1",
    GIT_CEILING_DIRECTORIES: "/sbx",
  });
});

test("shims for claude and gh refuse to run", () => {
  expect(failClosedShim("gh")).toContain("exit 97");
  expect(failClosedShim("gh")).toContain("gh");
});

test("suiteArgv runs the suite from the sandbox copy", () => {
  expect(suiteArgv("/sbx", entry("a", "porting"))).toEqual([
    "bash",
    "/sbx/repo/scripts/sw-a-test.sh",
  ]);
});

test("planStubs refuses a ported command that shares its script with an unported one", () => {
  const a = { ...entry("status", "porting"), script: "sw-status.sh" };
  const b = { ...entry("overview", "bash"), script: "sw-status.sh" };
  expect(() => planStubs([a, b], "/repo")).toThrow(/status.*overview|overview.*status/);
});

function listenUnix(path: string) {
  return new Promise<ReturnType<typeof createServer>>((resolve) => {
    const server = createServer();
    server.listen(path, () => resolve(server));
  });
}

test("socketsIn walks recursively, never follows symlinks, and ignores escapes", async () => {
  const sbx = tmp();
  const outside = mkdtempSync(join(tmpdir(), "o-"));
  const inner = await listenUnix(join(sbx, "s"));
  const out = await listenUnix(join(outside, "s"));
  try {
    mkdirSync(join(sbx, "a/b"), { recursive: true });
    const nested = await listenUnix(join(sbx, "a/b/n"));
    symlinkSync(join(outside, "s"), join(sbx, "link-to-outside-socket"));
    symlinkSync(outside, join(sbx, "link-to-outside-dir"));
    writeFileSync(join(sbx, "plain"), "");
    expect(socketsIn(sbx).sort()).toEqual([join(sbx, "a/b/n"), join(sbx, "s")]);
    const killed: string[][] = [];
    killSandboxTmux(sbx, (argv) => killed.push(argv));
    expect(killed.map((a) => a[2]).sort()).toEqual([join(sbx, "a/b/n"), join(sbx, "s")]);
    expect(killed[0]).toEqual(tmuxKillArgv(killed[0]?.[2] as string));
    nested.close();
  } finally {
    inner.close();
    out.close();
    rmSync(sbx, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  }
});

test("sweepStragglers refuses paths that are not parity sandboxes", () => {
  expect(() => sweepStragglers("/tmp")).toThrow(/refusing/);
  expect(() => sweepStragglers("/tmp/sw-parity-abc")).toThrow(/refusing/);
});

test("sweepStragglers SIGKILLs processes whose command line mentions the sandbox", async () => {
  const sbx = tmp();
  const proc = Bun.spawn(["bash", "-c", 'exec -a "$0" sleep 44', `${sbx}/marker`], {
    stdout: "ignore",
    stderr: "ignore",
  });
  try {
    await new Promise((r) => setTimeout(r, 150));
    sweepStragglers(sbx);
    await Promise.race([
      proc.exited,
      new Promise((_, rej) => setTimeout(() => rej(new Error("alive")), 3000)),
    ]);
    expect(proc.killed || proc.exitCode !== 0).toBe(true);
  } finally {
    proc.kill("SIGKILL");
    rmSync(sbx, { recursive: true, force: true });
  }
});

function git(cwd: string, ...args: string[]) {
  const env = {
    PATH: "/usr/bin:/bin:/opt/homebrew/bin",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
  };
  const r = Bun.spawnSync(["git", "-C", cwd, ...args], { env, stdout: "pipe", stderr: "pipe" });
  return { code: r.exitCode, out: new TextDecoder().decode(r.stdout).trim() };
}

function fixtureRepo(): string {
  const repo = tmp();
  git(repo, "init", "-q");
  mkdirSync(join(repo, "scripts"));
  mkdirSync(join(repo, "src"));
  mkdirSync(join(repo, "config"));
  mkdirSync(join(repo, "node_modules"));
  writeFileSync(join(repo, "src/cli.ts"), 'console.log("TS", ...Bun.argv.slice(2));\n');
  writeFileSync(join(repo, "config/c.json"), "{}");
  for (const n of ["hello", "other"]) {
    writeFileSync(join(repo, `scripts/sw-${n}.sh`), `#!/usr/bin/env bash\necho BASH ${n} "$@"\n`);
    chmodSync(join(repo, `scripts/sw-${n}.sh`), 0o755);
  }
  writeFileSync(join(repo, "untracked.txt"), "x");
  writeFileSync(join(repo, "node_modules/m"), "m");
  git(repo, "add", "src", "config", "scripts");
  return repo;
}

test("sandbox is a sealed copy of tracked files with only node_modules linked", async () => {
  const repo = fixtureRepo();
  const sbx = tmp();
  try {
    const copy = buildSandbox(sbx, repo, [entry("hello", "porting"), entry("other", "bash")]);
    const runner = new BunProcessRunner({ reapGroup: true });
    const env = { ...parityEnv(sbx, { PATH: "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" }) };
    const run = (name: string) => runner.run({ argv: [join(copy, "scripts", name), "x"], env });
    expect((await run("sw-hello.sh")).stdout.trim()).toBe("TS hello x");
    expect((await run("sw-other.sh")).stdout.trim()).toBe("BASH other x");
    expect(await Bun.file(join(repo, "scripts/sw-hello.sh")).text()).toContain("BASH hello");
    expect(await Bun.file(join(copy, "scripts/sw-hello.sh")).text()).toContain(
      `${copy}/src/cli.ts`,
    );
    expect(lstatSync(join(copy, "config")).isSymbolicLink()).toBe(false);
    expect(lstatSync(join(copy, "node_modules")).isSymbolicLink()).toBe(true);
    expect(existsSync(join(copy, "untracked.txt"))).toBe(false);
    expect(lstatSync(join(copy, "scripts/sw-other.sh")).mode & 0o111).not.toBe(0);
    for (const d of ["bin/claude", "bin/gh", "home", "tmp"])
      expect(existsSync(join(sbx, d))).toBe(true);
    // writes inside the sandbox never reach the fixture
    mkdirSync(join(copy, ".claude"));
    writeFileSync(join(copy, ".claude/x"), "x");
    expect(existsSync(join(repo, ".claude"))).toBe(false);
    // git cannot discover the real repo from inside the sandbox
    const rp = Bun.spawnSync(["git", "-C", copy, "rev-parse", "--show-toplevel"], {
      env,
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(rp.exitCode).not.toBe(0);
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(sbx, { recursive: true, force: true });
  }
});

test("gitSnapshot changes when ignored files, stashes or worktrees change", () => {
  const repo = fixtureRepo();
  try {
    writeFileSync(join(repo, ".gitignore"), "ign/\n");
    git(repo, "add", ".gitignore");
    const base = gitSnapshot(repo);
    expect(gitSnapshot(repo)).toBe(base);
    mkdirSync(join(repo, "ign"));
    writeFileSync(join(repo, "ign/f"), "x");
    expect(gitSnapshot(repo)).not.toBe(base);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});
