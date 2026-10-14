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

test("a failed incident write is an error", async () => {
  const github = new RecordingGithubWriter(err({ kind: "transient", message: "HTTP 502" }));
  const r = await checkBreaker(fakeSafetyPorts({ github, runs: fixedRuns(ok(fiveFailures)) }));
  expect(!r.ok && r.error.kind).toBe("transient");
});
