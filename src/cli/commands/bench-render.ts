import type { BenchReport } from "../../contexts/quality";

const pct = (v: number | null) => (v === null ? "—" : `${(v * 100).toFixed(1)}%`);
const usd = (v: number | null) => (v === null ? "—" : `$${v.toFixed(2)}`);
const ci = (c: readonly [number, number] | null) =>
  c === null ? "—" : `${pct(c[0])}–${pct(c[1])}`;
const pv = (p: number) => (p < 0.001 ? "<0.001" : p.toFixed(3));

type Arm = BenchReport["arms"][number];

function armRow(a: Arm, k: number): string[] {
  const all = a.graded + a.pending;
  const cost = a.costKnownRuns === all ? usd(a.totalCostUsd) : `${usd(a.totalCostUsd)} (partial)`;
  return [
    `${a.label} (${a.model})`,
    `${a.resolved}/${a.graded}`,
    pct(a.resolveRate),
    ci(a.ci95),
    k > 1 ? pct(a.passK) : "—",
    cost,
    usd(a.costPerResolvedUsd),
    a.medianMinutes === null ? "—" : a.medianMinutes.toFixed(1),
    `${a.errors}/${a.timeouts}/${a.pending}`,
    `${a.flagged}/${a.voided}`,
  ];
}

const HEAD = [
  "Arm",
  "Resolved",
  "Rate",
  "95% CI",
  "pass^k",
  "Spend",
  "$/resolved",
  "Median min",
  "Err/Timeout/Pending",
  "Flagged/Voided",
];

function pairLine(r: BenchReport, p: BenchReport["pairs"][number]): string {
  const name = (id: string) => r.arms.find((a) => a.armId === id)?.label ?? id;
  const counts = `${p.wins} wins, ${p.losses} losses, ${p.ties} ties over ${p.tasks} tasks`;
  return `${name(p.armId)} vs ${name(p.baselineId)}: ${counts} (sign test p = ${pv(p.p)})`;
}

const NOTE =
  "Errored and timed-out runs count as unresolved. Voided runs (the agent read the harness's full-history mirror or fetched the task's upstream repo) count as unresolved; flagged runs have warnings in results.jsonl. Spend is reported USD; partial means some runs reported none.";

/** The report as Markdown, for a PR, a README or the terminal. */
export function renderBenchMarkdown(r: BenchReport): string {
  const rows = [HEAD, HEAD.map(() => "---"), ...r.arms.map((a) => armRow(a, r.k))];
  return [
    `# Head-to-head: ${r.manifest}`,
    "",
    `${r.taskCount} tasks (${r.suites.join(", ")}), k = ${r.k}. Generated ${r.generatedAt}.`,
    "",
    ...rows.map((row) => `| ${row.join(" | ")} |`),
    "",
    "## Paired comparison",
    "",
    ...r.pairs.map((p) => `- ${pairLine(r, p)}`),
    "",
    NOTE,
  ].join("\n");
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

function htmlTable(r: BenchReport): string {
  const head = HEAD.map((h) => `<th>${esc(h)}</th>`).join("");
  const cells = (a: Arm) =>
    armRow(a, r.k)
      .map((c) => `<td>${esc(c)}</td>`)
      .join("");
  const body = r.arms.map((a) => `<tr>${cells(a)}</tr>`).join("");
  return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function bar(a: Arm): string {
  const w = ((a.resolveRate ?? 0) * 100).toFixed(1);
  const [lo, hi] = a.ci95 ?? [0, 0];
  const ciStyle = `left:${(lo * 100).toFixed(1)}%;width:${((hi - lo) * 100).toFixed(1)}%`;
  const track = `<span class="fill" style="width:${w}%"></span><span class="ci" style="${ciStyle}"></span>`;
  return `<div class="bar"><span>${esc(a.label)}</span><span class="track">${track}</span><span class="val">${pct(a.resolveRate)}</span></div>`;
}

const CSS = `:root{--bg:#fbfaf7;--fg:#1d1c1a;--muted:#6b675f;--line:#e4e0d8;--accent:#2f6f5e;--ci:#1d1c1a66}
@media (prefers-color-scheme:dark){:root{--bg:#161614;--fg:#eceae4;--muted:#a19c92;--line:#2e2c28;--accent:#6cc2a6;--ci:#eceae466}}
body{background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif;max-width:960px;margin:0 auto;padding:24px 16px}
h1{font-size:1.6rem;margin:0 0 4px}.meta{color:var(--muted)}
.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;white-space:nowrap}th{color:var(--muted);font-weight:500}
.bar{display:grid;grid-template-columns:minmax(90px,200px) 1fr 64px;gap:8px;align-items:center;margin:6px 0}
.track{position:relative;height:14px;background:var(--line);border-radius:3px}
.fill{position:absolute;top:0;bottom:0;left:0;background:var(--accent);border-radius:3px}
.ci{position:absolute;top:5px;height:4px;background:var(--ci)}.val{text-align:right;font-variant-numeric:tabular-nums}`;

/** A self-contained results page (no scripts, no external assets), light and dark. */
export function renderBenchHtml(r: BenchReport): string {
  const meta = `${r.taskCount} tasks (${esc(r.suites.join(", "))}) · k = ${r.k} · generated ${esc(r.generatedAt)}`;
  const pairs = r.pairs.map((p) => `<li>${esc(pairLine(r, p))}</li>`).join("");
  return [
    '<!doctype html><html lang="en"><head><meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width,initial-scale=1">',
    `<title>Shipwright head-to-head</title><style>${CSS}</style></head><body>`,
    `<h1>Head-to-head: ${esc(r.manifest)}</h1><p class="meta">${meta}</p>`,
    `<h2>Resolve rate</h2><p class="meta">Bar: rate. Line: 95% Wilson interval.</p>${r.arms.map(bar).join("")}`,
    `<h2>Results</h2><div class="scroll">${htmlTable(r)}</div>`,
    `<h2>Paired comparison</h2><ul>${pairs}</ul><p class="meta">${esc(NOTE)}</p>`,
    "</body></html>",
  ].join("\n");
}
