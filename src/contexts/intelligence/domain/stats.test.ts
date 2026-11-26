import { expect, test } from "bun:test";
import { routingStats } from "./stats";
import { run } from "./test-fixtures";

test("per-tier success rate and cost per success", () => {
  const runs = [
    run("docs", "trivial", "success", { costUsd: 1 }),
    run("docs", "trivial", "failure", { costUsd: 2 }),
    run("feature", "large", "success", { costUsd: 20, mode: "apply" }),
    run("feature", "large", "success"),
  ];
  const s = routingStats(runs, 6);
  expect(s.runs).toBe(4);
  expect(s.open).toBe(2);
  expect(s.byMode).toEqual({ shadow: 3, apply: 1 });
  const trivial = s.tiers.find((t) => t.tier === "trivial");
  expect(trivial).toMatchObject({
    runs: 2,
    successes: 1,
    successRate: 0.5,
    costUsd: 3,
    costPerSuccessUsd: 3,
  });
  const large = s.tiers.find((t) => t.tier === "large");
  expect(large).toMatchObject({ runs: 2, costed: 1, costPerSuccessUsd: 10 });
  expect(s.tiers.find((t) => t.tier === "small")).toMatchObject({ runs: 0, successRate: null });
});
