import { expect, test } from "bun:test";
import {
  EARLY_STOP_RULE,
  type StopProbe,
  spendAfterStop,
  stopTrigger,
  wouldStopAt,
} from "./early-stop";

const probe = (index: number, p: number | null, eligible = true): StopProbe => ({
  id: `a${index + 1}`,
  index,
  eligible,
  p,
});

test("stops at the first eligible attempt that reaches the threshold", () => {
  const probes = [probe(0, 0.5), probe(1, 0.85), probe(2, 0.95)];
  expect(wouldStopAt(probes, EARLY_STOP_RULE)).toBe(2);
  expect(stopTrigger(probes, EARLY_STOP_RULE)?.id).toBe("a2");
  expect(wouldStopAt([probe(0, 0.8)], EARLY_STOP_RULE)).toBe(1);
});

test("never stops when no probe reaches the threshold", () => {
  const probes = [probe(0, 0.79), probe(1, 0.1)];
  expect(wouldStopAt(probes, EARLY_STOP_RULE)).toBeNull();
  expect(stopTrigger(probes, EARLY_STOP_RULE)).toBeNull();
  expect(wouldStopAt([], EARLY_STOP_RULE)).toBeNull();
  expect(wouldStopAt(probes, { ...EARLY_STOP_RULE, threshold: 0.75 })).toBe(1);
});

test("ineligible attempts and unscored attempts never trigger a stop", () => {
  expect(wouldStopAt([probe(0, 0.99, false), probe(1, null)], EARLY_STOP_RULE)).toBeNull();
  expect(wouldStopAt([probe(0, 0.99, false), probe(1, null), probe(2, 0.9)], EARLY_STOP_RULE)).toBe(
    3,
  );
});

test("minAttempts delays the stop, and is null until that many attempts have run", () => {
  const rule = { threshold: 0.8, minAttempts: 2 };
  expect(wouldStopAt([probe(0, 0.9)], rule)).toBeNull();
  expect(wouldStopAt([probe(0, 0.9), probe(1, 0.1)], rule)).toBe(2);
  expect(stopTrigger([probe(0, 0.9), probe(1, 0.1)], rule)?.id).toBe("a1");
});

test("the saving is what the attempts after the stop point cost", () => {
  const costs = [
    { index: 0, costUsd: 3.1 },
    { index: 1, costUsd: 4.2 },
    { index: 2, costUsd: 5.204 },
  ];
  expect(spendAfterStop(costs, 1)).toBe(9.4);
  expect(spendAfterStop(costs, 3)).toBe(0);
  expect(spendAfterStop(costs, null)).toBe(0);
});
