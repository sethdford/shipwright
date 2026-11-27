import { describe, expect, it } from "vitest";
import { __test } from "./quality";
import type { QualitySummary } from "../types/api";

const empty = (): QualitySummary => ({
  generatedAt: "2026-11-26T12:00:00Z",
  windowDays: 30,
  scorecard: { available: false, savedAt: null, card: null, truncated: false },
  router: { decisions: 0, runs: 0, open: 0, byMode: { shadow: 0, apply: 0 }, tiers: [], recent: [] },
  verifier: {
    model: {
      available: false, source: null, trainedAt: null, evidence: null, trusted: false,
      untrustedReason: "no trained model (run shipwright verify train)",
    },
    gate: { counts: {}, recent: [] },
  },
  tournament: { counts: {}, recent: [] },
  acceptance: { counts: {}, recent: [] },
  governance: { counts: {}, recent: [] },
  safety: { counts: {}, recent: [] },
  repoModel: { counts: {}, recent: [] },
  cost: { runs: 0, totalUsd: 0, reported: 0, estimated: 0, unknownSource: 0, withPr: 0, recent: [] },
});

describe("quality view", () => {
  it("says what to run when nothing has been recorded", () => {
    const html = __test.render(empty());
    expect(html).toContain("shipwright scorecard --format json");
    expect(html).toContain("PIPELINE_ATTEMPTS");
    expect(html).toContain("advisory: no trained model");
  });

  it("renders the scorecard, router and cost, escaping recorded text", () => {
    const q = empty();
    q.scorecard = {
      available: true, savedAt: "2026-11-26T09:00:00Z", truncated: false,
      card: { closed: 10, merged: 2, mergeRate: 0.2, cleanMergeRate: 0.1, revertRate: 0,
        medianHoursToMerge: 5, costPerMergeUsd: null, windowDays: 365 },
    };
    q.router = {
      decisions: 1, runs: 1, open: 0, byMode: { shadow: 1, apply: 0 },
      tiers: [{ tier: "medium", runs: 1, successes: 1, successRate: 1, costPerSuccessUsd: 4 }],
      recent: [{ at: "2026-11-26T10:00:00Z", issue: 7, mode: "shadow", tier: "medium",
        template: "<b>x</b>", model: "opus", effort: "high", attempts: 1, result: "success",
        costUsd: 4, pr: 9 }],
    };
    q.cost = { runs: 1, totalUsd: 4, reported: 1, estimated: 0, unknownSource: 0, withPr: 1,
      recent: [{ ts: "2026-11-26T11:00:00Z", issue: 7, pr: 9, cost_usd: 4, cost_source: "reported" }] };
    const html = __test.render(q);
    expect(html).toContain("20% (2/10)");
    expect(html).toContain("Cost per merged PR");
    expect(html).toContain("unknown");
    expect(html).toContain("$4.00");
    expect(html).not.toContain("<b>x</b>");
    expect(html).toContain("&lt;b&gt;x&lt;/b&gt;");
  });
});
