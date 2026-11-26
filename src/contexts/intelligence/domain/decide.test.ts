import { describe, expect, test } from "bun:test";
import { type DecideRequest, decideRoute, fitBudget, historyStep } from "./decide";
import { extractFeatures } from "./features";
import type { RouteOverrides } from "./records";
import { ROUTING_V1 } from "./routes";
import { run } from "./test-fixtures";

const req = (
  title: string,
  more: {
    remainingUsd?: number;
    previousFailure?: string;
    overrides?: RouteOverrides;
    labels?: string[];
  } = {},
): DecideRequest => ({
  id: "rt-1",
  at: "2026-11-26T00:00:00.000Z",
  mode: "shadow",
  inputs: {
    features: extractFeatures({ title, body: "", labels: more.labels ?? [] }),
    overrides: more.overrides ?? {},
    ...(more.remainingUsd === undefined ? {} : { remainingUsd: more.remainingUsd }),
    ...(more.previousFailure === undefined ? {} : { previousFailure: more.previousFailure }),
  },
});

describe("decideRoute", () => {
  test("routes a trivial issue to the cheap single-attempt route and logs its inputs", () => {
    const d = decideRoute(req("docs: fix typo"), []);
    expect(d.difficulty.tier).toBe("trivial");
    expect(d.route).toEqual(ROUTING_V1.trivial);
    expect(d.applied).toMatchObject({
      template: "cost-aware",
      model: "sonnet",
      effort: "low",
      attempts: 1,
    });
    expect(d.policy).toBe("routing-v1");
    expect(d.inputs.features.kind).toBe("docs");
    expect(d.action).toBe("build");
  });

  test("a large issue gets parallel attempts", () => {
    const d = decideRoute(req("feat: thing", { labels: ["size/L"] }), []);
    expect(d.applied.attempts).toBe(3);
    expect(d.applied.model).toBe("opus");
  });

  test("caller overrides win, and attempts stay within 1..5", () => {
    const o = { model: "haiku", attempts: 9, template: "tdd" };
    const d = decideRoute(req("docs: fix typo", { overrides: o }), []);
    expect(d.applied).toMatchObject({
      model: "haiku",
      attempts: 5,
      template: "tdd",
      effort: "low",
    });
    expect(d.route.model).toBe("sonnet");
  });

  test("a retry after a budget or max_turns failure moves up exactly one tier", () => {
    const d = decideRoute(req("docs: fix typo", { previousFailure: "max_turns" }), []);
    expect(d.difficulty.prior).toBe("trivial");
    expect(d.difficulty.tier).toBe("small");
    expect(d.adjustments[0]).toContain("max_turns");
    expect(
      decideRoute(req("docs: fix typo", { previousFailure: "execution" }), []).difficulty.tier,
    ).toBe("trivial");
  });

  test("no money left defers the run; xl work carries split advice", () => {
    expect(decideRoute(req("docs: typo", { remainingUsd: 0 }), []).action).toBe("defer");
    expect(decideRoute(req("feat: x", { labels: ["size/XL"] }), []).advice).toContain("split");
  });
});

describe("historyStep (escalate only)", () => {
  test("escalates a bucket that failed most of at least three runs", () => {
    const h = [
      run("docs", "trivial", "failure"),
      run("docs", "trivial", "failure"),
      run("docs", "trivial", "success"),
    ];
    expect(historyStep("trivial", "docs/trivial", h).tier).toBe("small");
  });

  test("too few runs, a good record, or infrastructure failures change nothing", () => {
    const two = [run("docs", "trivial", "failure"), run("docs", "trivial", "failure")];
    expect(historyStep("trivial", "docs/trivial", two).tier).toBe("trivial");
    const good = [
      run("bug", "small", "success"),
      run("bug", "small", "success"),
      run("bug", "small", "failure"),
    ];
    expect(historyStep("small", "bug/small", good).tier).toBe("small");
    const infra = ["auth", "environment", "contamination"].map((c) =>
      run("docs", "trivial", "failure", { failureClass: c }),
    );
    expect(historyStep("trivial", "docs/trivial", infra).tier).toBe("trivial");
  });

  test("a perfect record never lowers the tier", () => {
    const h = [1, 2, 3, 4, 5].map(() => run("feature", "large", "success"));
    expect(historyStep("large", "feature/large", h).tier).toBe("large");
  });
});

describe("fitBudget (tighten only)", () => {
  test("drops attempts first, then lowers the cap to what is left", () => {
    const f = fitBudget(ROUTING_V1.large, 21);
    expect(f.route.attempts).toBe(2);
    expect(f.route.budgetUsd).toBe(21);
    expect(f.notes).toHaveLength(2);
  });

  test("never raises anything when there is money to spare or no cap", () => {
    expect(fitBudget(ROUTING_V1.large, 1000).route).toEqual(ROUTING_V1.large);
    expect(fitBudget(ROUTING_V1.large, undefined).route).toEqual(ROUTING_V1.large);
  });

  test("keeps at least one attempt", () => {
    expect(fitBudget(ROUTING_V1.large, 3).route.attempts).toBe(1);
  });
});
