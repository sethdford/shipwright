// Quality tab - the proof, verification and safety stack: delivery scorecard, merge verifier,
// compute router, tournaments, acceptance tests, governance and lessons, trust boundary, cost.
// Data: GET /api/quality (dashboard/services/quality.ts). Read-only.

import { escapeHtml } from "../core/helpers";
import * as api from "../core/api";
import type { QualityEventGroup, QualityRow, QualitySummary, View } from "../types/api";

type Cell = unknown;

const pct = (v: unknown): string =>
  typeof v === "number" ? `${Math.round(v * 100)}%` : "—";
const usd = (v: unknown): string =>
  typeof v === "number" ? `$${v.toFixed(2)}` : "unknown";
const val = (v: Cell): string => (v === null || v === undefined ? "—" : String(v));
const txt = (v: Cell): string => escapeHtml(val(v));
const day = (v: unknown): string => (typeof v === "string" ? v.slice(0, 16).replace("T", " ") : "—");

function tiles(items: [string, string][]): string {
  return (
    '<div class="ctx-eff-grid">' +
    items
      .map(
        ([label, value]) =>
          `<div class="ctx-eff-card"><span class="ctx-eff-card-label">${escapeHtml(label)}</span>` +
          `<span class="ctx-eff-value">${escapeHtml(value)}</span></div>`,
      )
      .join("") +
    "</div>"
  );
}

function table(head: string[], rows: Cell[][]): string {
  if (rows.length === 0) return "";
  return (
    '<div class="pipeline-table-wrap"><table class="pipeline-table"><thead><tr>' +
    head.map((h) => `<th>${escapeHtml(h)}</th>`).join("") +
    "</tr></thead><tbody>" +
    rows.map((r) => `<tr>${r.map((c) => `<td>${txt(c)}</td>`).join("")}</tr>`).join("") +
    "</tbody></table></div>"
  );
}

const hint = (text: string): string => `<div class="empty-state"><p>${escapeHtml(text)}</p></div>`;

function counts(g: QualityEventGroup): [string, string][] {
  return Object.entries(g.counts).map(([k, n]) => [k, String(n)]);
}

function section(title: string, body: string): string {
  return `<section class="section"><h2 class="section-label">${escapeHtml(title)}</h2>${body}</section>`;
}

function scorecard(s: QualitySummary["scorecard"]): string {
  const c = s.card;
  if (!s.available || !c) {
    return hint(
      "No saved scorecard. Run: shipwright scorecard --format json > ~/.shipwright/scorecard.json",
    );
  }
  return (
    tiles([
      ["Merge rate", `${pct(c.mergeRate)} (${val(c.merged)}/${val(c.closed)})`],
      ["Merged without help", pct(c.cleanMergeRate)],
      ["Reverted in 14 days", pct(c.revertRate)],
      ["Median hours to merge", val(c.medianHoursToMerge)],
      ["Cost per merged PR", usd(c.costPerMergeUsd)],
      ["Window", `${val(c.windowDays)} days, saved ${day(s.savedAt)}`],
    ]) + (s.truncated ? hint("The PR list was truncated; numbers cover the PRs read.") : "")
  );
}

function verifier(v: QualitySummary["verifier"]): string {
  const m = v.model;
  const e = m.evidence ?? {};
  const status = m.trusted ? "trusted to block on probability" : `advisory: ${m.untrustedReason}`;
  return (
    tiles([
      ["Model", m.available ? `${m.source}, ${val(e.examples)} factory PRs` : "prior only"],
      ["Leave-one-out AUC", val(e.looAuc)],
      ["Brier vs base rate", `${val(e.looBrier)} / ${val(e.baseBrier)}`],
      ...counts(v.gate),
    ]) +
    hint(status) +
    table(
      ["When", "Issue", "Verdict", "Merge chance"],
      v.gate.recent.map((r) => [day(r.ts), r.issue, r.verdict ?? r.type, r.merge_chance]),
    )
  );
}

function router(r: QualitySummary["router"]): string {
  if (r.decisions === 0) return hint("No routing decisions yet. Each pipeline run logs one.");
  return (
    tiles([
      ["Decisions", String(r.decisions)],
      ["Finished runs", String(r.runs)],
      ["Shadow / apply", `${r.byMode.shadow} / ${r.byMode.apply}`],
      ["Still open", String(r.open)],
    ]) +
    table(
      ["Tier", "Runs", "Success rate", "Cost per success"],
      r.tiers.map((t) => [t.tier, t.runs, pct(t.successRate), t.runs ? usd(t.costPerSuccessUsd) : null]),
    ) +
    table(
      ["When", "Issue", "Mode", "Tier", "Score", "Route", "Result", "Cost", "PR"],
      r.recent.map((d) => [
        day(d.at), d.issue, d.mode, d.tier, d.score,
        `${d.template} · ${d.model}/${d.effort} · ×${d.attempts}`,
        d.result, d.costUsd === null ? null : usd(d.costUsd), d.pr,
      ]),
    )
  );
}

function events(g: QualityEventGroup, empty: string, row: (r: QualityRow) => Cell[], head: string[]) {
  if (g.recent.length === 0) return hint(empty);
  return tiles(counts(g)) + table(head, g.recent.map(row));
}

function render(q: QualitySummary): string {
  const c = q.cost;
  return (
    `<div class="insights-grid">` +
    hint(`Last ${q.windowDays} days. Generated ${day(q.generatedAt)}.`) +
    section("Delivery scorecard", scorecard(q.scorecard)) +
    section("Merge verifier", verifier(q.verifier)) +
    section("Compute router", router(q.router)) +
    section(
      "Tournaments",
      events(q.tournament, "No tournament builds. Set PIPELINE_ATTEMPTS=2..5 to run one.",
        (r) => [day(r.ts), r.issue, r.attempts, r.winner, r.confidence, usd(r.cost_usd)],
        ["When", "Issue", "Attempts", "Winner", "Confidence", "Cost"]),
    ) +
    section(
      "Acceptance tests",
      events(q.acceptance, "No acceptance-test events yet.",
        (r) => [day(r.ts), r.issue, r.type, r.mode ?? r.reason ?? r.attempts],
        ["When", "Issue", "Event", "Detail"]),
    ) +
    section(
      "Governance and lessons",
      events(q.governance, "No governance briefs yet.",
        (r) => [day(r.ts), r.type, r.lessons ?? r.id ?? r.reason, r.docs,
          `${r.lessons_arm ?? "on"}/${r.governance_arm ?? "on"}`],
        ["When", "Event", "Lessons", "Docs", "Arms (lessons/gov)"]),
    ) +
    section(
      "Trust boundary",
      events(q.safety, "No refusals or patch handoffs yet.",
        (r) => [day(r.ts), r.issue, r.type], ["When", "Issue", "Event"]),
    ) +
    section(
      "Cost per run",
      c.runs === 0
        ? hint("No pipeline cost records in this window.")
        : tiles([
            ["Runs", String(c.runs)],
            ["Total", usd(c.totalUsd)],
            ["Reported / estimated", `${c.reported} / ${c.estimated}`],
            ["Linked to a PR", String(c.withPr)],
          ]) +
            table(["When", "Issue", "PR", "Cost", "Source"],
              c.recent.map((r) => [day(r.ts), r.issue, r.pr, usd(r.cost_usd), r.cost_source])),
    ) +
    section("Repository model", events(q.repoModel, "No repository-model events yet.",
      (r) => [day(r.ts), r.type, r.arm], ["When", "Event", "Arm"])) +
    "</div>"
  );
}

function load(): void {
  const panel = document.getElementById("panel-quality");
  if (!panel) return;
  api
    .fetchQuality(30)
    .then((q) => {
      panel.innerHTML = render(q);
    })
    .catch((e: Error) => {
      panel.innerHTML = hint(`Could not load quality data: ${e.message}`);
    });
}

export const qualityView: View = {
  init() {
    load();
  },
  render() {},
  destroy() {},
};

export const __test = { render };
