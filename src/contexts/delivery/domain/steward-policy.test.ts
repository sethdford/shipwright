import { expect, test } from "bun:test";
import type { CheckFailure, ChecksSummary } from "./steward-ci";
import {
  DEFAULT_LIMITS,
  decideNext,
  EMPTY_HISTORY,
  type StewardHistory,
  type StewardObservation,
} from "./steward-policy";
import type { ActionableComment } from "./steward-reviews";

const checks = (over: Partial<ChecksSummary> = {}): ChecksSummary => ({
  total: 3,
  pending: 0,
  passed: 3,
  failed: 0,
  ...over,
});
const failure = (name: string, kind: CheckFailure["kind"], jobId: number | null = 1) => ({
  name,
  kind,
  jobId,
  signature: `${name}: error`,
  excerpt: "error",
});
const ask = (id: number): ActionableComment => ({
  id,
  threadId: id,
  kind: "conversation",
  author: "alice",
  path: null,
  line: null,
  body: "Please rename.",
  intent: "change",
});
const obs = (over: Partial<StewardObservation> = {}): StewardObservation => ({
  prState: "open",
  checks: checks(),
  failures: [],
  comments: [],
  ...over,
});
const hist = (over: Partial<StewardHistory> = {}): StewardHistory => ({
  ...EMPTY_HISTORY,
  ...over,
});

test("green and nothing to answer: done", () => {
  expect(decideNext(obs(), EMPTY_HISTORY).action).toBe("done");
});

test("merged is done and closed is stop, whatever else is going on", () => {
  const busy = { failures: [failure("unit", "code")], comments: [ask(1)] };
  expect(decideNext(obs({ prState: "merged", ...busy }), EMPTY_HISTORY).action).toBe("done");
  const closed = decideNext(obs({ prState: "closed", ...busy }), EMPTY_HISTORY);
  expect(closed.action).toBe("stop");
  expect(closed.fixFailures).toEqual([]);
});

test("a code failure gets a fix round carrying it", () => {
  const unit = failure("unit", "code");
  const d = decideNext(obs({ checks: checks({ failed: 1 }), failures: [unit] }), EMPTY_HISTORY);
  expect(d.action).toBe("fix");
  expect(d.fixFailures).toEqual([unit]);
  expect(d.reason).toContain("unit");
});

test("a code failure is fixed even while other checks still run", () => {
  const o = obs({ checks: checks({ pending: 2 }), failures: [failure("unit", "code")] });
  expect(decideNext(o, EMPTY_HISTORY).action).toBe("fix");
});

test("review comments alone get a fix round", () => {
  const d = decideNext(obs({ comments: [ask(1), ask(2)] }), EMPTY_HISTORY);
  expect(d.action).toBe("fix");
  expect(d.fixComments.map((c) => c.id)).toEqual([1, 2]);
  expect(d.reason).toBe("2 review comment(s)");
});

test("the round limit stops the steward", () => {
  const o = obs({ comments: [ask(1)] });
  expect(decideNext(o, hist({ rounds: 2 })).action).toBe("fix");
  const d = decideNext(o, hist({ rounds: 3 }));
  expect(d.action).toBe("stop");
  expect(d.reason).toContain("round limit (3)");
  expect(decideNext(o, hist({ rounds: 0 }), { ...DEFAULT_LIMITS, maxRounds: 0 }).action).toBe(
    "stop",
  );
});

test("the same failure signature targeted twice stops: no progress", () => {
  const unit = failure("unit", "code");
  const o = obs({ failures: [unit] });
  expect(decideNext(o, hist({ rounds: 1, fixedSignatures: [[unit.signature]] })).action).toBe(
    "fix",
  );
  const stuck = hist({ rounds: 2, fixedSignatures: [[unit.signature], [unit.signature]] });
  const d = decideNext(o, stuck);
  expect(d.action).toBe("stop");
  expect(d.reason).toContain("no progress");
});

test("a stuck failure is left out while other work remains", () => {
  const unit = failure("unit", "code");
  const lint = failure("lint", "code");
  const h = hist({ rounds: 2, fixedSignatures: [[unit.signature], [unit.signature]] });
  const d = decideNext(obs({ failures: [unit, lint], comments: [ask(4)] }), h);
  expect(d.action).toBe("fix");
  expect(d.fixFailures.map((f) => f.name)).toEqual(["lint"]);
  expect(d.fixComments.map((c) => c.id)).toEqual([4]);
});

test("a comment offered too often is dropped", () => {
  const h = hist({ commentAttempts: { "1": 2, "2": 1 } });
  const d = decideNext(obs({ comments: [ask(1), ask(2)] }), h);
  expect(d.fixComments.map((c) => c.id)).toEqual([2]);
  const only = decideNext(obs({ comments: [ask(1)] }), h);
  expect(only.action).toBe("done");
});

test("infra failures: re-run once, then stop", () => {
  const e2e = failure("e2e", "infra", 77);
  const o = obs({ checks: checks({ failed: 1 }), failures: [e2e] });
  const first = decideNext(o, EMPTY_HISTORY);
  expect(first.action).toBe("rerun");
  expect(first.rerunJobs).toEqual([77]);
  expect(first.rerunChecks).toEqual(["e2e"]);
  const again = decideNext(o, hist({ rerunChecks: ["e2e"] }));
  expect(again.action).toBe("stop");
  expect(again.reason).toContain("persist after a re-run");
});

test("a re-run job's new id does not earn the same check a second re-run", () => {
  const rerun = obs({ failures: [failure("e2e", "infra", 78)] });
  expect(decideNext(rerun, hist({ rerunChecks: ["e2e"] })).action).toBe("stop");
  const other = obs({ failures: [failure("e2e", "infra", 78), failure("lint", "infra", 79)] });
  const d = decideNext(other, hist({ rerunChecks: ["e2e"] }));
  expect([d.action, d.rerunJobs, d.rerunChecks]).toEqual(["rerun", [79], ["lint"]]);
});

test("infra re-run waits for running checks before giving up", () => {
  const o = obs({ checks: checks({ pending: 1 }), failures: [failure("e2e", "infra", 77)] });
  expect(decideNext(o, hist({ rerunChecks: ["e2e"] })).action).toBe("wait");
});

test("an infra failure without a job id cannot be re-run", () => {
  const d = decideNext(obs({ failures: [failure("status", "infra", null)] }), EMPTY_HISTORY);
  expect(d.action).toBe("stop");
  expect(d.reason).toContain("cannot be re-run here");
  expect(d.rerunJobs).toEqual([]);
});

test("a PR from a fork stops before anything else", () => {
  const d = decideNext(
    obs({ fork: true, failures: [failure("unit", "code")], comments: [ask(1)] }),
    EMPTY_HISTORY,
  );
  expect(d.action).toBe("stop");
  expect(d.reason).toContain("fork");
  expect(decideNext(obs({ fork: false }), EMPTY_HISTORY).action).toBe("done");
  expect(decideNext(obs({ fork: true, prState: "merged" }), EMPTY_HISTORY).action).toBe("done");
});

test("no checks at all is not green: wait", () => {
  const d = decideNext(obs({ checks: checks({ total: 0, passed: 0 }) }), EMPTY_HISTORY);
  expect(d.action).toBe("wait");
  expect(d.reason).toBe("no checks reported on this commit yet");
  const asked = decideNext(
    obs({ checks: checks({ total: 0 }), comments: [ask(1)] }),
    EMPTY_HISTORY,
  );
  expect(asked.action).toBe("fix");
});

test("code failures take priority over infra re-runs", () => {
  const o = obs({ failures: [failure("e2e", "infra", 7), failure("unit", "code")] });
  const d = decideNext(o, EMPTY_HISTORY);
  expect(d.action).toBe("fix");
  expect(d.rerunJobs).toEqual([]);
});

test("pending checks with nothing to fix: wait", () => {
  expect(decideNext(obs({ checks: checks({ pending: 2 }) }), EMPTY_HISTORY).action).toBe("wait");
});

test("baseline failures do not block done", () => {
  const o = obs({ checks: checks({ failed: 1 }), failures: [failure("lint", "baseline")] });
  const d = decideNext(o, EMPTY_HISTORY);
  expect(d.action).toBe("done");
  expect(d.reason).toContain("also failing on the base: lint");
});

test("decisions other than fix carry no work items", () => {
  for (const d of [
    decideNext(obs(), EMPTY_HISTORY),
    decideNext(obs({ checks: checks({ pending: 1 }) }), EMPTY_HISTORY),
  ]) {
    expect(d.fixFailures).toEqual([]);
    expect(d.fixComments).toEqual([]);
    expect(d.rerunJobs).toEqual([]);
    expect(d.rerunChecks).toEqual([]);
  }
});

test("after the caller's grace period, no checks means no CI: done", () => {
  const d = decideNext(
    obs({ noChecksOk: true, checks: checks({ total: 0, passed: 0 }) }),
    EMPTY_HISTORY,
  );
  expect(d.action).toBe("done");
  expect(d.reason).toContain("no CI");
});
