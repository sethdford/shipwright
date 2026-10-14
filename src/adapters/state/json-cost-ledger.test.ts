import { afterEach, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { JsonCostLedger } from "./json-cost-ledger";

let env: TestEnv | undefined;
afterEach(() => env?.cleanup());
const write = (name: string, json: unknown) =>
  writeFileSync(join((env as TestEnv).stateDir, name), JSON.stringify(json));

test("missing files mean no cap, no spend and no data", async () => {
  env = createTestEnv();
  expect(await new JsonCostLedger(env.stateDir).read()).toEqual({
    ok: true,
    value: { budget: null, entries: [], present: false },
  });
});

test("either file alone counts as data", async () => {
  env = createTestEnv();
  write("costs.json", { entries: [], summary: {} });
  const r = await new JsonCostLedger(env.stateDir).read();
  expect(r.ok && r.value.present).toBe(true);
});

test("reads the files sw-cost.sh writes", async () => {
  env = createTestEnv();
  write("budget.json", { daily_budget_usd: 25, enabled: true });
  write("costs.json", {
    entries: [
      {
        input_tokens: 1,
        output_tokens: 2,
        model: "opus",
        stage: "build",
        issue: "42",
        cost_usd: 1.5,
        ts: "t",
        ts_epoch: 1760400000,
      },
      { cost_usd: "oops", ts_epoch: 1760400001 },
    ],
    summary: {},
  });
  expect(await new JsonCostLedger(env.stateDir).read()).toEqual({
    ok: true,
    value: {
      budget: { limitUsd: 25 },
      entries: [{ costUsd: 1.5, atEpochS: 1760400000 }],
      present: true,
    },
  });
});

test.each([[{ daily_budget_usd: 25, enabled: false }], [{ daily_budget_usd: 0, enabled: true }]])(
  "a disabled or zero budget (%p) is no cap",
  async (budget) => {
    env = createTestEnv();
    write("budget.json", budget);
    const r = await new JsonCostLedger(env.stateDir).read();
    expect(r.ok && r.value.budget).toBeNull();
  },
);

test("a corrupt budget file is an error, not 'unlimited'", async () => {
  env = createTestEnv();
  writeFileSync(join(env.stateDir, "budget.json"), "{not json");
  const r = await new JsonCostLedger(env.stateDir).read();
  expect(!r.ok && r.error.kind).toBe("failed");
});
