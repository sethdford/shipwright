import { describe, expect, test } from "bun:test";
import {
  type BreakerPolicy,
  breakerAllowsDispatch,
  breakerIncident,
  breakerPolicy,
  describeBreaker,
  evaluateBreaker,
  type RunRecord,
} from "./breaker";

const MIN = 60_000;
const policy: BreakerPolicy = { window: 8, maxFailures: 5, coolDownMs: 30 * MIN };
const done = (id: string, startMin: number, endMin: number, ok: boolean): RunRecord => ({
  id,
  startedAt: startMin * MIN,
  finished: { at: endMin * MIN, outcome: ok ? "success" : "failure" },
});
const cancelled = (id: string, startMin: number, endMin: number): RunRecord => ({
  id,
  startedAt: startMin * MIN,
  finished: { at: endMin * MIN, outcome: "cancelled" },
});
const active = (id: string, startMin: number): RunRecord => ({
  id,
  startedAt: startMin * MIN,
  finished: null,
});
/** n runs, one per minute from `fromMin`, each lasting one minute. */
const series = (fromMin: number, outcomes: readonly boolean[]): RunRecord[] =>
  outcomes.map((ok, i) => done(`r${fromMin + i}`, fromMin + i, fromMin + i + 1, ok));

describe("evaluateBreaker", () => {
  test("no history is closed and allows dispatch", () => {
    const s = evaluateBreaker([], 0, policy);
    expect(s).toEqual({ kind: "closed", failures: 0, considered: 0 });
    expect(breakerAllowsDispatch(s)).toBe(true);
  });

  test("4 failures in the last 8 stays closed", () => {
    const runs = series(0, [false, true, false, true, false, true, false, true]);
    expect(evaluateBreaker(runs, 100 * MIN, policy)).toEqual({
      kind: "closed",
      failures: 4,
      considered: 8,
    });
  });

  test("only the last `window` runs count", () => {
    const runs = series(0, [
      false,
      false,
      false,
      false,
      true,
      true,
      true,
      true,
      true,
      true,
      true,
      true,
    ]);
    expect(evaluateBreaker(runs, 100 * MIN, policy)).toMatchObject({ kind: "closed", failures: 0 });
  });

  test("the 5th failure in 8 opens it; dispatch stops until the cool-down ends", () => {
    const runs = series(0, [false, true, false, false, true, false, false]); // 5th failure ends at 7
    const s = evaluateBreaker(runs, 10 * MIN, policy);
    expect(s).toEqual({ kind: "open", since: 7 * MIN, probeAfter: 37 * MIN });
    expect(breakerAllowsDispatch(s)).toBe(false);
  });

  test("input order does not matter", () => {
    const runs = series(0, [false, false, false, false, false]).reverse();
    expect(evaluateBreaker(runs, 6 * MIN, policy)).toMatchObject({ kind: "open", since: 5 * MIN });
  });

  test("runs already in flight when it opened do not close it", () => {
    const runs = [...series(0, [false, false, false, false, false]), done("late", 4, 20, true)];
    expect(evaluateBreaker(runs, 21 * MIN, policy)).toMatchObject({ kind: "open", since: 5 * MIN });
  });

  test("after the cool-down it is half-open and allows exactly one probe", () => {
    const tripped = series(0, [false, false, false, false, false]); // opens at 5, probe after 35
    const s = evaluateBreaker(tripped, 40 * MIN, policy);
    expect(s).toEqual({ kind: "half_open", since: 5 * MIN, probing: false });
    expect(breakerAllowsDispatch(s)).toBe(true);
  });

  test("a probe in flight blocks further dispatch", () => {
    const runs = [...series(0, [false, false, false, false, false]), active("probe", 36)];
    const s = evaluateBreaker(runs, 40 * MIN, policy);
    expect(s).toEqual({ kind: "half_open", since: 5 * MIN, probing: true });
    expect(breakerAllowsDispatch(s)).toBe(false);
  });

  test("a successful probe closes it with a fresh window", () => {
    const runs = [...series(0, [false, false, false, false, false]), done("probe", 36, 50, true)];
    expect(evaluateBreaker(runs, 51 * MIN, policy)).toEqual({
      kind: "closed",
      failures: 0,
      considered: 0,
    });
  });

  test("a failed probe re-opens it from the probe's end", () => {
    const runs = [...series(0, [false, false, false, false, false]), done("probe", 36, 50, false)];
    expect(evaluateBreaker(runs, 51 * MIN, policy)).toEqual({
      kind: "open",
      since: 50 * MIN,
      probeAfter: 80 * MIN,
    });
  });
});

describe("describeBreaker", () => {
  test("names the state and its times", () => {
    expect(describeBreaker({ kind: "closed", failures: 2, considered: 8 })).toBe(
      "closed (2 of the last 8 runs failed)",
    );
    expect(describeBreaker({ kind: "open", since: 0, probeAfter: 30 * MIN })).toBe(
      "open since 1970-01-01T00:00:00.000Z; probe allowed after 1970-01-01T00:30:00.000Z",
    );
    expect(describeBreaker({ kind: "half_open", since: 0, probing: true })).toBe(
      "half-open since 1970-01-01T00:00:00.000Z; probe run in flight",
    );
    expect(describeBreaker({ kind: "half_open", since: 0, probing: false })).toBe(
      "half-open since 1970-01-01T00:00:00.000Z; one probe run allowed",
    );
  });
});

describe("breakerIncident", () => {
  test("names the trip time and the policy", () => {
    const report = breakerIncident({ kind: "open", since: 0, probeAfter: 30 * MIN }, policy);
    expect(report.title).toBe("Shipwright circuit breaker is open: dispatch stopped");
    expect(report.body).toContain("1970-01-01T00:00:00.000Z");
    expect(report.body).toContain("5 of the last 8");
    expect(report.body).toContain("shipwright:pause");
  });
});

const tripped = series(0, [false, false, false, false, false]); // opens at 5; probeAfter 35

describe("cancelled runs", () => {
  test("all cancelled stays closed with nothing considered", () => {
    const runs = [cancelled("a", 0, 1), cancelled("b", 1, 2), cancelled("c", 2, 3)];
    expect(evaluateBreaker(runs, 10 * MIN, policy)).toEqual({
      kind: "closed",
      failures: 0,
      considered: 0,
    });
  });

  test("cancelled runs do not push failures out of the window", () => {
    const runs = [
      ...series(0, [false, false, false, false]),
      ...[4, 5, 6, 7, 8, 9, 10, 11].map((i) => cancelled(`c${i}`, i, i + 1)),
    ];
    expect(evaluateBreaker(runs, 20 * MIN, policy)).toEqual({
      kind: "closed",
      failures: 4,
      considered: 4,
    });
  });

  test("a cancelled probe does not settle it: half-open, not probing", () => {
    const runs = [...tripped, cancelled("probe", 36, 40)];
    expect(evaluateBreaker(runs, 41 * MIN, policy)).toEqual({
      kind: "half_open",
      since: 5 * MIN,
      probing: false,
    });
  });
});

describe("probe abandonment", () => {
  test("a probe in flight longer than the cool-down no longer blocks dispatch", () => {
    const runs = [...tripped, active("stuck", 36)];
    const s = evaluateBreaker(runs, (36 + 30) * MIN + 1, policy);
    expect(s).toEqual({ kind: "half_open", since: 5 * MIN, probing: false });
    expect(breakerAllowsDispatch(s)).toBe(true);
  });

  test("a probe exactly one cool-down old still counts as in flight", () => {
    const runs = [...tripped, active("probe", 36)];
    expect(evaluateBreaker(runs, (36 + 30) * MIN, policy)).toMatchObject({ probing: true });
  });
});

describe("ordering", () => {
  test("ties on completion time are broken by start time, then id", () => {
    const closedWithOneFailure = { kind: "closed", failures: 1, considered: 1 } as const;
    // Both finish at 40. In order a, b: success closes it, then b's failure is the only one in
    // the window. The other order would end at 0 failures, so the result shows the order used.
    const a = done("a", 36, 40, true);
    const b = done("b", 37, 40, false);
    expect(evaluateBreaker([...tripped, a, b], 41 * MIN, policy)).toEqual(closedWithOneFailure);
    expect(evaluateBreaker([...tripped, b, a], 41 * MIN, policy)).toEqual(closedWithOneFailure);
    // Same start and end: the id decides, whatever the input order.
    const x = done("x", 36, 40, true);
    const y = done("y", 36, 40, false);
    expect(evaluateBreaker([...tripped, x, y], 41 * MIN, policy)).toEqual(closedWithOneFailure);
    expect(evaluateBreaker([...tripped, y, x], 41 * MIN, policy)).toEqual(closedWithOneFailure);
  });
});

describe("policy validation", () => {
  test("accepts a sane policy", () => {
    expect(breakerPolicy(policy)).toEqual(policy);
  });

  test.each([
    { window: 0, maxFailures: 1, coolDownMs: MIN },
    { window: 8, maxFailures: 0, coolDownMs: MIN },
    { window: 8, maxFailures: 9, coolDownMs: MIN },
    { window: 8, maxFailures: 5, coolDownMs: 0 },
    { window: 8, maxFailures: 5, coolDownMs: -1 },
    { window: 8.5, maxFailures: 5, coolDownMs: MIN },
    { window: 8, maxFailures: Number.NaN, coolDownMs: MIN },
  ])("rejects %p", (bad) => {
    expect(() => breakerPolicy(bad)).toThrow();
    expect(() => evaluateBreaker([], 0, bad)).toThrow();
  });
});

describe("boundaries", () => {
  test("at probeAfter it is half-open; one ms earlier it is open", () => {
    expect(evaluateBreaker(tripped, 35 * MIN, policy)).toMatchObject({ kind: "half_open" });
    expect(evaluateBreaker(tripped, 35 * MIN - 1, policy)).toMatchObject({ kind: "open" });
  });

  test("a run created exactly at probeAfter is the probe; one ms earlier it is not", () => {
    const probe = (startedAt: number): RunRecord => ({
      id: "p",
      startedAt,
      finished: { at: 50 * MIN, outcome: "success" },
    });
    expect(evaluateBreaker([...tripped, probe(35 * MIN)], 51 * MIN, policy)).toMatchObject({
      kind: "closed",
    });
    expect(evaluateBreaker([...tripped, probe(35 * MIN - 1)], 51 * MIN, policy)).toMatchObject({
      kind: "half_open",
      probing: false,
    });
  });

  test("failed probe, re-open, second probe succeeds: closed", () => {
    const runs = [...tripped, done("p1", 36, 50, false), done("p2", 81, 90, true)];
    expect(evaluateBreaker(runs, 91 * MIN, policy)).toEqual({
      kind: "closed",
      failures: 0,
      considered: 0,
    });
    expect(evaluateBreaker(runs.slice(0, 6), 60 * MIN, policy)).toMatchObject({ kind: "open" });
  });

  test("the oldest failure sliding out of the window keeps it closed at 4", () => {
    const runs = series(0, [false, true, false, false, false, true, true, true, false]);
    // Window = last 8 (runs 1..8): 4 failures; run 0's failure has left.
    expect(evaluateBreaker(runs, 100 * MIN, policy)).toEqual({
      kind: "closed",
      failures: 4,
      considered: 8,
    });
  });
});
