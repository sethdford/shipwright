import { expect, test } from "bun:test";
import {
  type CheckRun,
  checkState,
  cleanLog,
  failureExcerpt,
  failureSignature,
  isInfraLog,
  latestRuns,
  summarizeChecks,
  triageFailures,
} from "./steward-ci";

const run = (name: string, over: Partial<CheckRun> = {}): CheckRun => ({
  name,
  status: "completed",
  conclusion: "success",
  jobId: 100,
  ...over,
});

test("check states", () => {
  expect(checkState(run("a", { status: "queued", conclusion: null }))).toBe("pending");
  expect(checkState(run("a", { status: "in_progress", conclusion: "failure" }))).toBe("pending");
  expect(checkState(run("a", { conclusion: null }))).toBe("pending");
  expect(checkState(run("a"))).toBe("passed");
  for (const c of ["neutral", "skipped", "cancelled", "stale", "something-new"]) {
    expect(checkState(run("a", { conclusion: c }))).toBe("neutral");
  }
  for (const c of ["failure", "timed_out", "startup_failure"]) {
    expect(checkState(run("a", { conclusion: c }))).toBe("failed");
  }
  // Waiting for someone's approval: no fix round can do that.
  expect(checkState(run("a", { conclusion: "action_required" }))).toBe("pending");
});

test("infra logs: runner, network, quota and credentials", () => {
  const infra = [
    "The runner has received a shutdown signal.",
    "##[error]No space left on device",
    "API rate limit exceeded for installation",
    "npm ERR! code ECONNRESET",
    "fatal: unable to access: Could not resolve host: github.com",
    "HTTP 503 Service Unavailable",
    "Error: Bad credentials",
    "Error: Resource not accessible by integration",
    "The job was not started because recent account payments have failed",
  ];
  for (const log of infra) expect(isInfraLog(log)).toBe(true);
  expect(isInfraLog("expect(received).toBe(expected)\n  Expected: 2\n  Received: 3")).toBe(false);
  expect(isInfraLog("")).toBe(false);
});

test("cleanLog strips timestamps, colour codes and CRLF", () => {
  const log = "2026-11-01T10:00:00.1234567Z \u001b[31merror\u001b[0m: boom  \r\nnext";
  expect(cleanLog(log)).toEqual(["error: boom", "next"]);
});

test("the excerpt keeps context around errors and drops noise", () => {
  const log = [
    "##[group]Other step output",
    "setup 1",
    "setup 2",
    "##[endgroup]",
    "setup 3",
    "setup 4",
    "ok 1 adds",
    "not ok 2 subtracts",
    "  expected 1 but got 2",
    "done",
  ].join("\n");
  const ex = failureExcerpt(log);
  expect(ex).not.toContain("##[group]");
  expect(ex).not.toContain("##[endgroup]");
  expect(ex).not.toContain("setup 2");
  expect(ex.split("\n")[0]).toBe("setup 3");
  expect(ex).toContain("not ok 2 subtracts");
});

test("the excerpt falls back to the tail and respects both caps", () => {
  const lines = Array.from({ length: 200 }, (_, i) => `line ${i}`);
  const ex = failureExcerpt(lines.join("\n"), 10);
  expect(ex.split("\n")).toEqual(lines.slice(-10));
  const long = failureExcerpt(`error: ${"x".repeat(10_000)}`, 80, 100);
  expect(long.length).toBe(100);
  expect(failureExcerpt("")).toBe("");
});

test("echoed step scripts and env inside a Run group are not log output", () => {
  const log = [
    "##[group]Run if [ -z \"$TOKEN\" ]; then echo 'token not set'; exit 1; fi",
    "if [ -z \"$TOKEN\" ]; then echo 'error: token not set'; exit 1; fi",
    "env:",
    "  RETRY_ON: rate limit",
    "##[endgroup]",
    "src/a.test.ts:3 error: expected 1 to be 2",
    "##[error]Process completed with exit code 1.",
  ].join("\n");
  expect(cleanLog(log)).toEqual([
    "src/a.test.ts:3 error: expected 1 to be 2",
    "##[error]Process completed with exit code 1.",
  ]);
  const [f] = triageFailures([{ run: run("unit", { conclusion: "failure" }), log }], new Set());
  expect(f?.kind).toBe("code");
  expect(f?.excerpt).not.toContain("token not set");
  expect(f?.signature).toBe("unit: src/a.test.ts:N error: expected N to be N");
});

test("infra is judged on the excerpt, not on stray words anywhere in the log", () => {
  const filler = Array.from({ length: 30 }, (_, i) => `step ${i}`);
  const log = ["retrying after rate limit", ...filler, "error: expected 1 to be 2"].join("\n");
  expect(isInfraLog(log)).toBe(true);
  const [f] = triageFailures([{ run: run("unit", { conclusion: "failure" }), log }], new Set());
  expect(f?.kind).toBe("code");
});

test("the signature uses the last real error line", () => {
  const log = [
    "warning: deprecated error-prone API",
    "error: first thing",
    "error: the real failure at line 7",
    "##[error]Process completed with exit code 1.",
  ].join("\n");
  expect(failureSignature("unit", log)).toBe("unit: error: the real failure at line N");
  expect(failureSignature("unit", "##[error]Process completed with exit code 2.")).toBe("unit: ");
});

test("the signature is stable across runs and blurs numbers and hashes", () => {
  const a = failureSignature("test", "ok\nsrc/a.ts:12:5 error TS2322 at 3f9a2b1c\nmore");
  const b = failureSignature("test", "ok\nsrc/a.ts:40:9 error TS2322 at 77aa001e\nother");
  expect(a).toBe(b);
  expect(a).toBe("test: src/a.ts:N:N error TSN at #");
  expect(failureSignature("lint", "")).toBe("lint: ");
  expect(failureSignature("x", `error ${"y".repeat(500)}`).length).toBe("x: ".length + 160);
  expect(failureSignature("t", "error: a")).not.toBe(failureSignature("t", "error: b"));
});

test("triage: baseline beats infra beats code", () => {
  const out = triageFailures(
    [
      { run: run("unit", { conclusion: "failure", jobId: 1 }), log: "error: expected 1" },
      { run: run("e2e", { conclusion: "failure", jobId: 2 }), log: "ECONNRESET" },
      { run: run("slow", { conclusion: "timed_out", jobId: 3 }), log: "" },
      { run: run("boot", { conclusion: "startup_failure", jobId: 4 }), log: "" },
      { run: run("lint", { conclusion: "failure", jobId: 5 }), log: "ECONNRESET" },
    ],
    new Set(["lint"]),
  );
  expect(out.map((f) => [f.name, f.kind, f.jobId])).toEqual([
    ["unit", "code", 1],
    ["e2e", "infra", 2],
    ["slow", "infra", 3],
    ["boot", "infra", 4],
    ["lint", "baseline", 5],
  ]);
  expect(out[0]?.signature).toBe("unit: error: expected N");
  expect(out[0]?.excerpt).toBe("error: expected 1");
});

test("latest runs are kept per app and name", () => {
  const runs = [
    run("ci", { app: "github-actions", conclusion: "failure" }),
    run("ci", { app: "status", conclusion: "success" }),
    run("ci", { app: "github-actions", conclusion: "success" }),
  ];
  expect(latestRuns(runs).map((r) => [r.app, r.conclusion])).toEqual([
    ["github-actions", "failure"],
    ["status", "success"],
  ]);
  expect(summarizeChecks(runs)).toEqual({ total: 2, pending: 0, passed: 1, failed: 1 });
});

test("latest runs: the first per name wins; the summary counts one per name", () => {
  const runs = [
    run("unit", { conclusion: "success" }),
    run("unit", { conclusion: "failure" }),
    run("lint", { status: "in_progress", conclusion: null }),
    run("e2e", { conclusion: "failure" }),
    run("docs", { conclusion: "skipped" }),
  ];
  expect(latestRuns(runs).map((r) => r.conclusion)).toEqual([
    "success",
    null,
    "failure",
    "skipped",
  ]);
  expect(summarizeChecks(runs)).toEqual({ total: 4, pending: 1, passed: 1, failed: 1 });
  expect(summarizeChecks([])).toEqual({ total: 0, pending: 0, passed: 0, failed: 0 });
});

test("a group the log never closes cannot hide the rest of the log", () => {
  const lines = cleanLog(["##[group]Run x", "secret step", "FAIL real error"].join("\n"));
  expect(lines).toContain("FAIL real error");
});
