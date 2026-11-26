// Quality read model for the dashboard's Quality tab: the proof, verification and safety stack
// (scorecard, compute router, merge verifier, tournaments, acceptance tests, governance, cost).
//
// Pure: every function takes already-read data and returns a summary. The files are read in
// quality-sources.ts. The dashboard may not import src/ (D1), so the router stats here mirror
// src/contexts/intelligence/domain/stats.ts in a reduced form; the CLI stays the source of truth.

export type Row = Record<string, unknown>;

const TIERS = ["trivial", "small", "medium", "large", "xl"] as const;
const RECENT = 12;

const num = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) ? v : null;
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const round2 = (n: number): number => Math.round(n * 100) / 100;
const obj = (v: unknown): Row => (v && typeof v === "object" ? (v as Row) : {});

/** Parses JSON lines, skipping blank or malformed lines (the dashboard is a viewer, not a gate). */
export function parseJsonLines(text: string): Row[] {
  const out: Row[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      const v = JSON.parse(line);
      if (v && typeof v === "object") out.push(v as Row);
    } catch {
      // skip
    }
  }
  return out;
}

// ─── Scorecard ──────────────────────────────────────────────────────

export interface ScorecardSummary {
  available: boolean;
  savedAt: string | null;
  card: Row | null;
  truncated: boolean;
}

/** `shipwright scorecard --format json` output, saved to a file; null when absent or not one. */
export function summarizeScorecard(parsed: unknown, savedAt: string | null): ScorecardSummary {
  const card = obj(obj(parsed).card);
  if (num(card.closed) === null) return { available: false, savedAt, card: null, truncated: false };
  return { available: true, savedAt, card, truncated: obj(parsed).truncated === true };
}

// ─── Compute router ─────────────────────────────────────────────────

export interface TierRow {
  tier: string;
  runs: number;
  successes: number;
  successRate: number | null;
  costPerSuccessUsd: number | null;
}

export interface RouterSummary {
  decisions: number;
  runs: number;
  open: number;
  byMode: { shadow: number; apply: number };
  tiers: TierRow[];
  recent: Row[];
}

export function summarizeRouter(records: Row[]): RouterSummary {
  const decisions = new Map<string, Row>();
  const outcomes = new Map<string, Row>();
  for (const r of records) {
    if (r.kind === "decision" && str(r.id)) decisions.set(r.id as string, r);
    if (r.kind === "outcome" && str(r.decisionId)) outcomes.set(r.decisionId as string, r);
  }
  const runs = [...outcomes].flatMap(([id, o]) => {
    const d = decisions.get(id);
    return d ? [{ d, o }] : [];
  });
  const tierOf = (d: Row) => str(obj(d.difficulty).tier) ?? "unknown";
  const tiers = TIERS.map((tier) => {
    const mine = runs.filter((r) => tierOf(r.d) === tier);
    const ok = mine.filter((r) => r.o.result === "success").length;
    const costed = mine.filter((r) => num(r.o.costUsd) !== null);
    const cost = costed.reduce((s, r) => s + (num(r.o.costUsd) ?? 0), 0);
    return {
      tier,
      runs: mine.length,
      successes: ok,
      successRate: mine.length ? round2(ok / mine.length) : null,
      costPerSuccessUsd: ok && costed.length ? round2(cost / ok) : null,
    };
  });
  const recent = [...decisions.values()].slice(-RECENT).reverse().map((d) => {
    const o = outcomes.get(d.id as string);
    const applied = obj(d.applied);
    return {
      at: d.at, issue: d.issue, mode: d.mode, action: d.action, tier: tierOf(d),
      score: obj(d.difficulty).score, template: applied.template, model: applied.model,
      effort: applied.effort, attempts: applied.attempts, budgetUsd: applied.budgetUsd,
      result: o?.result ?? null, costUsd: o?.costUsd ?? null, pr: o?.pr ?? null,
    };
  });
  const modeCount = (m: string) => runs.filter((r) => r.d.mode === m).length;
  return {
    decisions: decisions.size,
    runs: runs.length,
    open: Math.max(0, decisions.size - runs.length),
    byMode: { shadow: modeCount("shadow"), apply: modeCount("apply") },
    tiers,
    recent,
  };
}

// ─── Merge verifier ─────────────────────────────────────────────────

/** Mirrors GATE_RULE in src/contexts/quality/domain/verifier-policy.ts. */
const GATE = { minExamples: 20, minEachOutcome: 5, minAuc: 0.7 };

export interface VerifierModelSummary {
  available: boolean;
  source: string | null;
  trainedAt: string | null;
  evidence: Row | null;
  trusted: boolean;
  untrustedReason: string | null;
}

export function summarizeVerifierModel(parsed: unknown): VerifierModelSummary {
  const model = obj(obj(parsed).model);
  const e = obj(obj(parsed).evidence);
  if (!str(model.source)) {
    return {
      available: false, source: null, trainedAt: null, evidence: null, trusted: false,
      untrustedReason: "no trained model (run shipwright verify train)",
    };
  }
  const n = num(e.examples) ?? 0;
  const each = Math.min(num(e.merged) ?? 0, num(e.unmerged) ?? 0);
  const auc = num(e.looAuc);
  const brier = num(e.looBrier);
  const base = num(e.baseBrier);
  let why: string | null = null;
  if (n < GATE.minExamples) why = `only ${n} labelled factory PRs (needs ${GATE.minExamples})`;
  else if (each < GATE.minEachOutcome) why = `needs ${GATE.minEachOutcome} merged and unmerged`;
  else if (auc === null || auc < GATE.minAuc) why = `leave-one-out AUC below ${GATE.minAuc}`;
  else if (brier === null || base === null || brier >= base) why = "does not beat the base rate";
  const trainedMs = num(model.trainedAtMs);
  return {
    available: true,
    source: model.source as string,
    trainedAt: trainedMs === null ? null : new Date(trainedMs).toISOString(),
    evidence: e,
    trusted: why === null,
    untrustedReason: why,
  };
}

// ─── Events ─────────────────────────────────────────────────────────

export interface EventGroup {
  counts: Record<string, number>;
  recent: Row[];
}

/** Counts by a field (or by type) and keeps the newest events, for one family of event types. */
export function groupEvents(events: Row[], types: readonly string[], by?: string): EventGroup {
  const counts: Record<string, number> = {};
  const mine = events.filter((e) => types.includes(e.type as string));
  for (const e of mine) {
    const key = String((by ? (e[by] ?? e.type) : e.type) ?? "unknown");
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return { counts, recent: mine.slice(-RECENT).reverse() };
}

export interface CostSummary {
  runs: number;
  totalUsd: number;
  reported: number;
  estimated: number;
  unknownSource: number;
  withPr: number;
  recent: Row[];
}

/** Per-run cost from `pipeline.cost` events (one per run; PR and source once recorded). */
export function summarizeCost(events: Row[]): CostSummary {
  const runs = events.filter((e) => e.type === "pipeline.cost");
  const src = (s: string) => runs.filter((e) => e.cost_source === s).length;
  return {
    runs: runs.length,
    totalUsd: round2(runs.reduce((s, e) => s + (num(e.cost_usd) ?? 0), 0)),
    reported: src("reported"),
    estimated: src("estimated"),
    unknownSource: runs.filter((e) => !str(e.cost_source)).length,
    withPr: runs.filter((e) => (num(e.pr) ?? 0) > 0).length,
    recent: runs.slice(-RECENT).reverse(),
  };
}

export const EVENT_FAMILIES = {
  verifier: ["pr.verifier", "pr.verifier_unavailable"],
  tournament: ["build.tournament"],
  acceptance: [
    "acceptance.locked", "acceptance.passed", "acceptance.failed", "acceptance.gate_failed",
    "acceptance.not_testable", "acceptance.skipped",
  ],
  governance: ["governance.brief", "governance.brief_unavailable", "lessons.drafted"],
  safety: [
    "intake.untrusted_refused", "decompose.untrusted_refused", "build.patch_applied",
    "build.patch_empty", "build.patch_refused",
  ],
  repoModel: ["repo_model.brief", "repo_model.brief_unavailable", "repo_model.mcp_attached",
    "repo_model.mcp_skipped"],
} as const;

export interface QualitySummary {
  generatedAt: string;
  windowDays: number;
  scorecard: ScorecardSummary;
  router: RouterSummary;
  verifier: { model: VerifierModelSummary; gate: EventGroup };
  tournament: EventGroup;
  acceptance: EventGroup;
  governance: EventGroup;
  safety: EventGroup;
  repoModel: EventGroup;
  cost: CostSummary;
}

export interface QualityInputs {
  nowMs: number;
  windowDays: number;
  events: Row[];
  routing: Row[];
  verifierModel: unknown;
  scorecard: unknown;
  scorecardSavedAt: string | null;
}

export function buildQualitySummary(i: QualityInputs): QualitySummary {
  const cutoff = i.nowMs / 1000 - i.windowDays * 86400;
  const ev = i.events.filter((e) => (num(e.ts_epoch) ?? 0) >= cutoff);
  const f = EVENT_FAMILIES;
  return {
    generatedAt: new Date(i.nowMs).toISOString(),
    windowDays: i.windowDays,
    scorecard: summarizeScorecard(i.scorecard, i.scorecardSavedAt),
    router: summarizeRouter(i.routing),
    verifier: {
      model: summarizeVerifierModel(i.verifierModel),
      gate: groupEvents(ev, f.verifier, "verdict"),
    },
    tournament: groupEvents(ev, f.tournament, "confidence"),
    acceptance: groupEvents(ev, f.acceptance),
    governance: groupEvents(ev, f.governance),
    safety: groupEvents(ev, f.safety),
    repoModel: groupEvents(ev, f.repoModel),
    cost: summarizeCost(ev),
  };
}
