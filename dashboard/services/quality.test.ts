import { describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  buildQualitySummary,
  groupEvents,
  parseJsonLines,
  summarizeCost,
  summarizeRouter,
  summarizeScorecard,
  summarizeVerifierModel,
} from "./quality";
import { loadQualitySummary, parseWindowDays, qualityPaths } from "./quality-sources";

const decision = (id: string, tier: string, mode = "shadow") => ({
  kind: "decision", schema: 1, id, at: "2026-11-26T10:00:00Z", mode, issue: 7, action: "build",
  difficulty: { score: 40, prior: tier, tier, reasons: [] },
  applied: { template: "standard", model: "opus", effort: "high", attempts: 1, budgetUsd: 12 },
});
const outcome = (id: string, result: string, costUsd?: number) => ({
  kind: "outcome", schema: 1, decisionId: id, at: "2026-11-26T11:00:00Z", result, costUsd,
});

describe("parseJsonLines", () => {
  it("skips blank and malformed lines", () => {
    expect(parseJsonLines('{"a":1}\n\nnot json\n{"b":2}\n')).toEqual([{ a: 1 }, { b: 2 }]);
  });
});

describe("summarizeRouter", () => {
  it("joins outcomes to decisions and reports cost per success by tier", () => {
    const s = summarizeRouter([
      decision("d1", "medium"), outcome("d1", "success", 4),
      decision("d2", "medium"), outcome("d2", "failure", 2),
      decision("d3", "large", "apply"),
      outcome("orphan", "success", 1),
    ]);
    expect(s.decisions).toBe(3);
    expect(s.runs).toBe(2);
    expect(s.open).toBe(1);
    expect(s.byMode).toEqual({ shadow: 2, apply: 0 });
    const medium = s.tiers.find((t) => t.tier === "medium");
    expect(medium).toEqual({
      tier: "medium", runs: 2, successes: 1, successRate: 0.5, costPerSuccessUsd: 6,
    });
    expect(s.recent[0]).toMatchObject({ tier: "large", result: null, mode: "apply" });
    expect(s.recent[1]).toMatchObject({ tier: "medium", result: "failure", costUsd: 2 });
  });

  it("reports no cost per success without a success or a cost", () => {
    const s = summarizeRouter([decision("d1", "small"), outcome("d1", "failure")]);
    expect(s.tiers.find((t) => t.tier === "small")?.costPerSuccessUsd).toBeNull();
  });
});

describe("summarizeVerifierModel", () => {
  const stored = (evidence: Record<string, unknown>) => ({
    model: { version: 1, source: "trained", trainedAtMs: 0, bias: 0, weights: {}, examples: 68 },
    evidence,
  });

  it("is untrusted with a dozen factory PRs, and says why", () => {
    const m = summarizeVerifierModel(
      stored({ examples: 12, merged: 2, unmerged: 10, looAuc: 0.45, looBrier: 0.18, baseBrier: 0.14 }),
    );
    expect(m.available).toBe(true);
    expect(m.trusted).toBe(false);
    expect(m.untrustedReason).toMatch(/only 12/);
  });

  it("is trusted when every gate rule holds", () => {
    const m = summarizeVerifierModel(
      stored({ examples: 30, merged: 10, unmerged: 20, looAuc: 0.8, looBrier: 0.1, baseBrier: 0.2 }),
    );
    expect(m.trusted).toBe(true);
    expect(m.trainedAt).toBe("1970-01-01T00:00:00.000Z");
  });

  it("does not trust a model that does not beat the base rate", () => {
    const m = summarizeVerifierModel(
      stored({ examples: 30, merged: 10, unmerged: 20, looAuc: 0.8, looBrier: 0.25, baseBrier: 0.2 }),
    );
    expect(m.untrustedReason).toMatch(/base rate/);
  });

  it("reports a missing model", () => {
    expect(summarizeVerifierModel(null)).toMatchObject({ available: false, trusted: false });
  });
});

describe("summarizeScorecard", () => {
  it("reads the card from scorecard JSON", () => {
    const s = summarizeScorecard({ card: { closed: 10, merged: 2 }, truncated: true }, "t");
    expect(s).toEqual({ available: true, savedAt: "t", card: { closed: 10, merged: 2 }, truncated: true });
  });
  it("is unavailable for anything else", () => {
    expect(summarizeScorecard({ nope: 1 }, null).available).toBe(false);
  });
});

describe("events", () => {
  it("groups by a field, falling back to the type", () => {
    const g = groupEvents(
      [
        { type: "pr.verifier", verdict: "warn" },
        { type: "pr.verifier", verdict: "warn" },
        { type: "pr.verifier_unavailable" },
        { type: "other" },
      ],
      ["pr.verifier", "pr.verifier_unavailable"],
      "verdict",
    );
    expect(g.counts).toEqual({ warn: 2, "pr.verifier_unavailable": 1 });
    expect(g.recent[0]?.type).toBe("pr.verifier_unavailable");
  });

  it("summarizes cost by source and PR link", () => {
    const c = summarizeCost([
      { type: "pipeline.cost", cost_usd: 1.25, cost_source: "reported", pr: 12 },
      { type: "pipeline.cost", cost_usd: 0.5, cost_source: "estimated", pr: 0 },
      { type: "pipeline.cost", cost_usd: 0 },
    ]);
    expect(c).toMatchObject({
      runs: 3, totalUsd: 1.75, reported: 1, estimated: 1, unknownSource: 1, withPr: 1,
    });
  });

  it("keeps only events inside the window", () => {
    const nowMs = 100 * 86400 * 1000;
    const q = buildQualitySummary({
      nowMs, windowDays: 1, routing: [], verifierModel: null, scorecard: null,
      scorecardSavedAt: null,
      events: [
        { type: "build.tournament", ts_epoch: 100 * 86400 - 10, confidence: "high" },
        { type: "build.tournament", ts_epoch: 90 * 86400, confidence: "low" },
      ],
    });
    expect(q.tournament.counts).toEqual({ high: 1 });
  });
});

describe("quality sources", () => {
  it("reads every file under the state dir and tolerates missing ones", () => {
    const home = mkdtempSync(join(tmpdir(), "sw-quality-"));
    const paths = qualityPaths(home);
    mkdirSync(join(home, ".shipwright", "routing"), { recursive: true });
    writeFileSync(paths.routingLog, `${JSON.stringify(decision("d1", "xl"))}\n`);
    writeFileSync(paths.eventsFile, `${JSON.stringify({ type: "governance.brief", ts_epoch: 1e12 })}\n`);
    const q = loadQualitySummary(paths, 30, 1e15);
    expect(q.router.decisions).toBe(1);
    expect(q.verifier.model.available).toBe(false);
    expect(q.scorecard.available).toBe(false);
  });

  it("uses an absolute SHIPWRIGHT_STATE_DIR for TypeScript command state, never a relative one", () => {
    expect(qualityPaths("/h", "/s").routingLog).toBe("/s/routing/decisions.jsonl");
    expect(qualityPaths("/h", "rel").routingLog).toBe("/h/.shipwright/routing/decisions.jsonl");
    expect(qualityPaths("/h", "/s").eventsFile).toBe("/h/.shipwright/events.jsonl");
  });

  it("bounds the window", () => {
    expect(parseWindowDays("7")).toBe(7);
    expect(parseWindowDays("0")).toBe(30);
    expect(parseWindowDays("abc")).toBe(30);
    expect(parseWindowDays(null)).toBe(30);
  });
});
