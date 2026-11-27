import type { ScanReport, StewardReport } from "../../contexts/delivery";

export function renderReport(r: StewardReport): string {
  const c = r.checks;
  const lines = [
    `PR #${r.pr} (${r.state}) at ${r.headSha.slice(0, 12)}`,
    `checks: ${c.passed} passed, ${c.failed} failed, ${c.pending} running (${c.total} total)`,
    ...r.failures.map((f) => `  ✗ ${f.name} [${f.kind}]`),
    `review comments to act on: ${r.comments.length}`,
    ...r.comments.map((m) => `  • ${m.id} ${m.author}${m.path ? ` ${m.path}` : ""} (${m.intent})`),
    `next: ${r.decision.action} — ${r.decision.reason}`,
  ];
  return lines.join("\n");
}

export function renderScan(r: ScanReport): string {
  if (r.findings.length === 0) return "✓ scan: nothing found in the added lines";
  const head =
    r.verdict === "block"
      ? "✗ scan: blocked"
      : r.verdict === "fix"
        ? "⚠ scan: needs a fix"
        : "✓ scan: notes only";
  return [
    head,
    ...r.findings.map((f) => `  ${f.severity} ${f.path}:${f.line} ${f.rule} — ${f.message}`),
  ].join("\n");
}
