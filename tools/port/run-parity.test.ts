import { expect, test } from "bun:test";
import type { ProgressEntry } from "./progress";
import { parityEnv, parityTimeoutMs, runBashSuite, selectSuites, summarize } from "./run-parity";

const entry = (command: string, status: ProgressEntry["status"], parity: string | null) => ({
  command,
  aliases: [],
  script: `sw-${command}.sh`,
  context: "platform",
  parity,
  status,
});

test("selects only active entries that have a parity suite", () => {
  const all: ProgressEntry[] = [
    entry("a", "bash", "scripts/sw-a-test.sh"),
    entry("b", "porting", "scripts/sw-b-test.sh"),
    entry("c", "parity-green", null),
    entry("d", "bash-deleted", "scripts/sw-d-test.sh"),
  ];
  expect(selectSuites(all).map((e) => e.command)).toEqual(["b", "d"]);
});

test("env is hermetic: private HOME and TMUX_TMPDIR, no inherited secrets", () => {
  const env = parityEnv("/sbx", { PATH: "/bin", GITHUB_TOKEN: "secret" });
  expect(env).toEqual({ PATH: "/bin", HOME: "/sbx/home", TMUX_TMPDIR: "/sbx", TERM: "dumb" });
});

test("timeout comes from SW_PARITY_TIMEOUT_MS, defaulting to 15 minutes", () => {
  expect(parityTimeoutMs({})).toBe(900_000);
  expect(parityTimeoutMs({ SW_PARITY_TIMEOUT_MS: "250" })).toBe(250);
  expect(parityTimeoutMs({ SW_PARITY_TIMEOUT_MS: "junk" })).toBe(900_000);
});

test("summarize counts passes and reports pass only when none failed", () => {
  expect(summarize(3, 1)).toEqual({ line: "2/3 parity suites passed", exitCode: 1 });
  expect(summarize(0, 0)).toEqual({ line: "0/0 parity suites passed", exitCode: 0 });
});

const run = (script: string, timeoutMs = 10_000) =>
  runBashSuite(["bash", "-c", script], { PATH: "/usr/bin:/bin" }, timeoutMs);

test("a chatty suite writing lots of stderr does not deadlock", async () => {
  const r = await run(`head -c 1000000 /dev/zero | tr '\\0' e >&2; echo done`);
  expect(r.timedOut).toBe(false);
  expect(r.code).toBe(0);
  expect(r.stdout).toContain("done");
}, 15_000);

test("a failing suite includes stderr in the output", async () => {
  const r = await run(`echo oops >&2; exit 3`);
  expect(r.code).toBe(3);
  expect(r.stderr).toContain("oops");
});

test("a hung suite is killed (with its children) and flagged timedOut", async () => {
  const start = Date.now();
  const r = await run(`sleep 30 & sleep 30`, 300);
  expect(r.timedOut).toBe(true);
  expect(r.code).not.toBe(0);
  expect(Date.now() - start).toBeLessThan(10_000);
}, 15_000);
