import type {
  Calibration,
  ScoreReport,
  StoredVerifier,
  TrainingReport,
} from "../../contexts/quality";

const pct = (p: number | null) =>
  p === null || Number.isNaN(p) ? "n/a" : `${Math.round(p * 100)}%`;
const num = (v: number | null, d = 3) => (v === null ? "n/a" : v.toFixed(d));

function calibrationLine(label: string, c: Calibration): string {
  const head = `  ${label.padEnd(26)} n=${String(c.n).padEnd(4)}`;
  return `${head} Brier ${num(c.brier)} (base rate ${num(c.baseBrier)})  AUC ${num(c.auc, 2)}  ECE ${num(c.ece)}`;
}

function modelLine(r: ScoreReport): string {
  return r.model === "trained"
    ? `  model: trained on ${r.examples} PRs`
    : "  model: hand-set prior (run `shipwright verify train` to learn from history)";
}

export function renderScore(r: ScoreReport): string {
  const v = r.decision.verdict;
  const icon = v === "block" ? "✗" : v === "warn" ? "⚠" : "✓";
  const lines = [
    `${icon} verifier: ${v}, predicted merge chance ${pct(r.probability)}`,
    modelLine(r),
  ];
  if (r.decision.wouldBe !== v) lines.push(`  enforce mode would: ${r.decision.wouldBe}`);
  for (const why of r.decision.reasons) lines.push(`  - ${why}`);
  if (r.drivers.length > 0) {
    const d = r.drivers.map((c) => `${c.feature} ${c.effect > 0 ? "+" : ""}${c.effect.toFixed(2)}`);
    lines.push(`  drivers (logit): ${d.join(", ")}`);
  }
  if (r.critic) {
    lines.push(`  critic: ${pct(r.critic.probability)}`);
    for (const c of r.critic.concerns) lines.push(`    concern ${c}`);
  }
  for (const n of r.notes) lines.push(`  note: ${n}`);
  if (r.costUsd > 0) lines.push(`  cost: $${r.costUsd.toFixed(2)}`);
  return lines.join("\n");
}

function gateLine(untrusted: string | null): string {
  return untrusted === null
    ? "Gate: trusted. In enforce mode a low predicted chance blocks."
    : `Gate: probability only warns (${untrusted}). Hard stops still block in enforce mode.`;
}

export function renderTraining(r: TrainingReport): string {
  const e = r.evidence;
  const lines = [
    `Verifier trained on ${e.examples} closed PRs (${e.merged} merged and kept, ${e.unmerged} not)${r.saved ? "" : ", not saved"}`,
    "",
    "Calibration",
    calibrationLine("all PRs, hand-set prior", r.prior),
    calibrationLine("all PRs, trained (LOO)", r.loo),
    calibrationLine("factory, hand-set prior", r.priorAgent),
    calibrationLine("factory, trained (LOO)", r.looAgent),
    "",
    gateLine(r.untrusted),
  ];
  const agent = r.examples.filter((x) => x.agent);
  if (agent.length > 0) lines.push("", "Factory PRs: outcome, leave-one-out chance, prior chance");
  for (const x of agent) {
    const outcome = x.merged ? "merged" : "closed";
    lines.push(
      `  #${String(x.number).padEnd(6)} ${outcome}  ${pct(x.looP).padStart(4)}  ${pct(x.priorP).padStart(4)}  ${x.title.slice(0, 56)}`,
    );
  }
  if (r.truncated) lines.push("", "⚠ more PRs than one page; older history was not read");
  return lines.join("\n");
}

export function renderStored(s: StoredVerifier | null): string {
  if (s === null) return "No trained verifier yet: scoring uses the hand-set prior.";
  const e = s.evidence;
  const when = s.model.trainedAtMs === null ? "n/a" : new Date(s.model.trainedAtMs).toISOString();
  const lines = [
    `Verifier trained ${when} on ${e.examples} PRs (${e.merged} merged, ${e.unmerged} not)`,
    `  leave-one-out AUC ${num(e.looAuc, 2)}, Brier ${num(e.looBrier)} (base rate ${num(e.baseBrier)})`,
    `  bias ${s.model.bias.toFixed(2)}`,
  ];
  for (const [f, w] of Object.entries(s.model.weights))
    lines.push(`  ${f.padEnd(18)} ${w.toFixed(2)}`);
  return lines.join("\n");
}
