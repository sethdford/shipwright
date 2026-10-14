import { describe, expect, test } from "bun:test";
import {
  type BreakerPolicy,
  breakerAllowsDispatch,
  breakerIncident,
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
