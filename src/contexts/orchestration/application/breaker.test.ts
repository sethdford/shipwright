import { expect, test } from "bun:test";
import { idempotencyKey } from "../../../shared/kernel/durability";
import { err, ok } from "../../../shared/kernel/result";
import {
  fakeSafetyPorts,
  fixedRuns,
  NOW,
  RecordingGithubWriter,
} from "../../../testing/fake-safety-ports";
import type { RunRecord } from "../domain/breaker";
import { breakerStatus, checkBreaker } from "./breaker";

const failed = (i: number): RunRecord => ({
  id: `r${i}`,
  startedAt: NOW - 60_000 * (10 - i),
  finished: { at: NOW - 60_000 * (9 - i), outcome: "failure" },
});
const fiveFailures = [0, 1, 2, 3, 4].map(failed); // last ends at NOW - 5 min

test("a closed breaker allows dispatch and writes nothing", async () => {
  const github = new RecordingGithubWriter();
  const r = await checkBreaker(fakeSafetyPorts({ github }));
  expect(r).toEqual({
    ok: true,
    value: { state: { kind: "closed", failures: 0, considered: 0 }, allowed: true, incident: null },
  });
  expect(github.calls).toHaveLength(0);
});

test("an open breaker blocks and ensures one incident keyed by the trip time", async () => {
  const github = new RecordingGithubWriter();
  const r = await checkBreaker(fakeSafetyPorts({ github, runs: fixedRuns(ok(fiveFailures)) }));
  const since = NOW - 5 * 60_000;
  expect(r.ok && r.value.allowed).toBe(false);
  expect(r.ok && r.value.incident).toEqual({ issue: 900, action: "created" });
  expect(github.calls).toHaveLength(1);
  expect(github.calls[0]?.key).toBe(idempotencyKey("breaker", "open", String(since)));
  expect(github.calls[0]?.report.title).toContain("circuit breaker is open");
});

test("status never writes, even when open", async () => {
  const github = new RecordingGithubWriter();
  const r = await breakerStatus(fakeSafetyPorts({ github, runs: fixedRuns(ok(fiveFailures)) }));
  expect(r.ok && r.value.state.kind).toBe("open");
  expect(github.calls).toHaveLength(0);
});

test("an unreadable history is an error (callers fail closed)", async () => {
  const runs = fixedRuns(err({ kind: "auth", message: "HTTP 401" }));
  expect(await checkBreaker(fakeSafetyPorts({ runs }))).toEqual({
    ok: false,
    error: { kind: "auth", message: "HTTP 401" },
  });
});

test("a failed incident write does not hide the open state", async () => {
  const github = new RecordingGithubWriter(err({ kind: "transient", message: "HTTP 502" }));
  const r = await checkBreaker(fakeSafetyPorts({ github, runs: fixedRuns(ok(fiveFailures)) }));
  expect(r.ok && r.value.allowed).toBe(false);
  expect(r.ok && r.value.state.kind).toBe("open");
  expect(r.ok && r.value.incident).toBeNull();
  expect(r.ok && r.value.incidentError).toBe("HTTP 502");
});

const cancelled = (i: number): RunRecord => ({
  id: `c${i}`,
  startedAt: NOW - 1000 - i,
  finished: { at: NOW - 500 - i, outcome: "cancelled" },
});

test("a full-length history with too few finished runs is indeterminate", async () => {
  const runs = [...fiveFailures.slice(0, 4), ...Array.from({ length: 46 }, (_, i) => cancelled(i))];
  const r = await breakerStatus(fakeSafetyPorts({ runs: fixedRuns(ok(runs)) }));
  expect(r).toEqual({
    ok: false,
    error: {
      kind: "failed",
      message: "breaker indeterminate: fewer than 8 finished runs in the last 50",
    },
  });
});

test("all-cancelled full history fails closed", async () => {
  const runs = Array.from({ length: 50 }, (_, i) => cancelled(i));
  const r = await checkBreaker(fakeSafetyPorts({ runs: fixedRuns(ok(runs)) }));
  expect(r.ok).toBe(false);
});

test("a short history (young repo) stays closed", async () => {
  const runs = Array.from({ length: 10 }, (_, i) => cancelled(i));
  const r = await breakerStatus(fakeSafetyPorts({ runs: fixedRuns(ok(runs)) }));
  expect(r.ok && r.value.allowed).toBe(true);
});

test("an invalid policy is an error, not a throw", async () => {
  const bad = { window: 0, maxFailures: 1, coolDownMs: 1 };
  const r = await checkBreaker(fakeSafetyPorts(), bad);
  expect(!r.ok && r.error.kind).toBe("failed");
});

test("half-open allows dispatch without an incident call", async () => {
  const github = new RecordingGithubWriter();
  const old = fiveFailures.map((r) => ({
    ...r,
    startedAt: r.startedAt - 3_600_000,
    finished: { at: (r.finished?.at ?? 0) - 3_600_000, outcome: "failure" as const },
  }));
  const r = await checkBreaker(fakeSafetyPorts({ github, runs: fixedRuns(ok(old)) }));
  expect(r.ok && r.value.state.kind).toBe("half_open");
  expect(r.ok && r.value.allowed).toBe(true);
  expect(github.calls).toHaveLength(0);
});

test("a re-trip gets a distinct incident key", async () => {
  const first = new RecordingGithubWriter();
  const second = new RecordingGithubWriter();
  await checkBreaker(fakeSafetyPorts({ github: first, runs: fixedRuns(ok(fiveFailures)) }));
  const later = fiveFailures.map((r) => ({
    ...r,
    startedAt: r.startedAt + 60_000,
    finished: { at: (r.finished?.at ?? 0) + 60_000, outcome: "failure" as const },
  }));
  await checkBreaker(fakeSafetyPorts({ github: second, runs: fixedRuns(ok(later)) }));
  expect(first.calls[0]?.key).not.toBe(second.calls[0]?.key);
});

test("an unchanged incident passes through", async () => {
  const github = new RecordingGithubWriter(ok({ issue: 900, action: "unchanged" }));
  const r = await checkBreaker(fakeSafetyPorts({ github, runs: fixedRuns(ok(fiveFailures)) }));
  expect(r.ok && r.value.incident).toEqual({ issue: 900, action: "unchanged" });
});
