import { expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BunProcessRunner } from "../../src/adapters/process/bun-process-runner";
import type { ProgressEntry } from "./progress";
import {
  buildSandbox,
  failClosedShim,
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
  return mkdtempSync(join(tmpdir(), "sw-sbx-test-"));
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

test("socketsIn lists only files inside the sandbox's tmux-* dirs", () => {
  const sbx = tmp();
  try {
    mkdirSync(join(sbx, "tmux-501"));
    writeFileSync(join(sbx, "tmux-501", "default"), "");
    mkdirSync(join(sbx, "other"));
    writeFileSync(join(sbx, "other", "x"), "");
    const outside = tmp();
    symlinkSync(outside, join(sbx, "tmux-evil"));
    expect(socketsIn(sbx)).toEqual([join(sbx, "tmux-501", "default")]);
    expect(tmuxKillArgv("/sbx/tmux-1/default")).toEqual([
      "tmux",
      "-S",
      "/sbx/tmux-1/default",
      "kill-server",
    ]);
    rmSync(outside, { recursive: true, force: true });
  } finally {
    rmSync(sbx, { recursive: true, force: true });
  }
});

test("sweepStragglers SIGKILLs processes whose command line mentions the sandbox", async () => {
  const sbx = tmp();
  const proc = Bun.spawn(["bash", "-c", "sleep 44; true", `marker-${sbx}`], {
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

test("a stubbed script in the sandbox copy runs the stub, an unstubbed one runs the original", async () => {
  const repo = tmp();
  const sbx = tmp();
  try {
    mkdirSync(join(repo, "scripts"));
    mkdirSync(join(repo, "src"));
    mkdirSync(join(repo, "config"));
    writeFileSync(join(repo, "src/cli.ts"), 'console.log("TS", ...Bun.argv.slice(2));\n');
    for (const n of ["hello", "other"]) {
      writeFileSync(join(repo, `scripts/sw-${n}.sh`), `#!/usr/bin/env bash\necho BASH ${n} "$@"\n`);
      chmodSync(join(repo, `scripts/sw-${n}.sh`), 0o755);
    }
    buildSandbox(sbx, repo, [entry("hello", "porting"), entry("other", "bash")]);
    const runner = new BunProcessRunner({ reapGroup: true });
    const run = (name: string) =>
      runner.run({
        argv: [join(sbx, "repo/scripts", name), "x"],
        env: { PATH: "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" },
      });
    expect((await run("sw-hello.sh")).stdout.trim()).toBe("TS hello x");
    expect((await run("sw-other.sh")).stdout.trim()).toBe("BASH other x");
    // the real script is untouched
    expect(await Bun.file(join(repo, "scripts/sw-hello.sh")).text()).toContain("BASH hello");
    // non-script top-level dirs are reachable, scripts/.git are not shared
    expect(await Bun.file(join(sbx, "repo/config")).exists()).toBe(false); // directory, not a file
    expect(Bun.spawnSync(["test", "-d", join(sbx, "repo/config")]).exitCode).toBe(0);
    expect(Bun.spawnSync(["test", "-e", join(sbx, "bin/claude")]).exitCode).toBe(0);
    expect(Bun.spawnSync(["test", "-d", join(sbx, "home")]).exitCode).toBe(0);
    expect(Bun.spawnSync(["test", "-d", join(sbx, "tmp")]).exitCode).toBe(0);
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(sbx, { recursive: true, force: true });
  }
});
