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

const failed = async () => {
  const r = await new JsonCostLedger((env as TestEnv).stateDir).read();
  return !r.ok && r.error.kind === "failed" ? r.error.message : null;
};

test.each([[[]], [{}], [{ entrees: [] }], [null]])(
  "a costs.json that is not {entries: [...]} (%p) is an error, not 'no spend'",
  async (costs) => {
    env = createTestEnv();
    write("budget.json", { daily_budget_usd: 25, enabled: true });
    write("costs.json", costs);
    expect(await failed()).toContain("costs.json");
  },
);

test("a budget.json holding JSON null is an error, not a missing file", async () => {
  env = createTestEnv();
  write("budget.json", null);
  expect(await failed()).toContain("budget.json");
});

test("a malformed entry is an error naming its index", async () => {
  env = createTestEnv();
  write("costs.json", {
    entries: [
      { cost_usd: 1, ts_epoch: 1 },
      { cost_usd: "oops", ts_epoch: 2 },
    ],
  });
  expect(await failed()).toMatch(/entries.*1/);
});

test("a negative cost is an error", async () => {
  env = createTestEnv();
  write("costs.json", { entries: [{ cost_usd: -1, ts_epoch: 1 }] });
  expect(await failed()).toContain("costs.json");
});

test("a negative daily budget is an error, not unlimited", async () => {
  env = createTestEnv();
  write("budget.json", { daily_budget_usd: -5, enabled: true });
  expect(await failed()).toContain("budget.json");
});
