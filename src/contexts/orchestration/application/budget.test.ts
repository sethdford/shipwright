import { expect, test } from "bun:test";
import { err, ok } from "../../../shared/kernel/result";
import { fakeSafetyPorts, fixedCosts, NOW } from "../../../testing/fake-safety-ports";
import { checkBudget } from "./budget";

const today = Math.floor(NOW / 1000);

test("checks today's spend plus the estimate against the cap", async () => {
  const costs = fixedCosts({ limitUsd: 5 }, [{ costUsd: 4, atEpochS: today }]);
  const ports = fakeSafetyPorts({ costs });
  expect(await checkBudget(ports, 0)).toEqual({
    ok: true,
    value: { allowed: true, limitUsd: 5, spentTodayUsd: 4, remainingUsd: 1 },
  });
  const over = await checkBudget(ports, 1);
  expect(over.ok && over.value.allowed).toBe(false);
});

test("no cost files at all is allowed but flagged as no data", async () => {
  const costs = { read: async () => ok({ budget: null, entries: [], present: false }) };
  const r = await checkBudget(fakeSafetyPorts({ costs }), 0);
  expect(r.ok && r.value.allowed).toBe(true);
  expect(r.ok && r.value.noData).toBe(true);
});

test("a recorded ledger with no cap is not flagged as no data", async () => {
  const r = await checkBudget(fakeSafetyPorts(), 0);
  expect(r.ok && r.value.noData).toBeUndefined();
});

test("an unreadable ledger is an error (callers fail closed)", async () => {
  const costs = { read: async () => err({ kind: "failed" as const, message: "bad json" }) };
  expect((await checkBudget(fakeSafetyPorts({ costs }), 0)).ok).toBe(false);
});
