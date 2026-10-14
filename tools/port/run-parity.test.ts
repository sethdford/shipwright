import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ProgressEntry } from "./progress";
import {
  gitChanged,
  parityTimeoutMs,
  runOne,
  runSuite,
  selectSuites,
  summarize,
} from "./run-parity";

const entry = (
  command: string,
  status: ProgressEntry["status"],
  parity: string | null,
): ProgressEntry => ({
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
  runSuite(["bash", "-c", script], { PATH: "/usr/bin:/bin" }, timeoutMs, tmpdir());

test("a chatty suite writing lots of stderr does not deadlock", async () => {
  const r = await run(`head -c 1000000 /dev/zero | tr '\\0' e >&2; echo done`);
  expect(r.timedOut).toBe(false);
  expect(r.exitCode).toBe(0);
  expect(r.stdout).toContain("done");
}, 15_000);

test("a failing suite includes stderr in the output", async () => {
  const r = await run(`echo oops >&2; exit 3`);
  expect(r.exitCode).toBe(3);
  expect(r.stderr).toContain("oops");
});

test("a hung suite times out and its background job is dead afterwards", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sw-hung-"));
  try {
    const pidFile = join(dir, "pid");
    const r = await run(`sleep 45 & echo $! > '${pidFile}'; sleep 45`, 400);
    expect(r.timedOut).toBe(true);
    const pid = Number(await Bun.file(pidFile).text());
    await new Promise((res) => setTimeout(res, 100));
    expect(() => process.kill(pid, 0)).toThrow();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}, 15_000);

test("gitChanged flags a differing porcelain snapshot", () => {
  expect(gitChanged(" M a\n", " M a\n")).toBe(false);
  expect(gitChanged(" M a\n", " M a\n?? b\n")).toBe(true);
});

test("a shared-script refusal fails that suite with the reason instead of crashing", async () => {
  const a = { ...entry("status", "porting", "scripts/sw-status-test.sh"), script: "sw-status.sh" };
  const b = { ...entry("overview", "bash", null), script: "sw-status.sh" };
  const errors: string[] = [];
  const original = console.error;
  console.error = (m: string) => errors.push(String(m));
  try {
    expect(await runOne(a, [a, b])).toBe(false);
  } finally {
    console.error = original;
  }
  expect(errors.join("\n")).toMatch(/✗ parity status.*shares it with unported command 'overview'/s);
});
