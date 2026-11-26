import {
  type GreenReport,
  type Materialized,
  REASON_HELP,
  type RedReport,
  type TestRun,
} from "../../contexts/planning";
import type { CliIO } from "../command";

type Reason = keyof typeof REASON_HELP;

function runLine(r: TestRun): string {
  const mark = r.verdict.ok ? "✓" : "✗";
  const why = r.verdict.ok
    ? r.verdict.reason
    : (REASON_HELP[r.verdict.reason as Reason] ?? r.verdict.reason);
  const evidence = r.verdict.evidence ? `\n    ${r.verdict.evidence}` : "";
  return `${mark} ${r.path}: ${why}${evidence}`;
}

/** Failing runs with their output tails: what the test writer or builder needs to fix it. */
function tails(io: CliIO, runs: readonly TestRun[]): void {
  for (const r of runs.filter((x) => !x.verdict.ok)) {
    io.out(`\n--- ${r.path} (${r.argv.join(" ")}) ---\n${r.tail}`);
  }
}

export function renderMaterialized(io: CliIO, m: Materialized): void {
  if (!m.ok) {
    io.out("✗ acceptance answer rejected; nothing was written:");
    for (const p of m.problems) io.out(`  - ${p}`);
  } else if (m.kind === "not_testable") {
    io.out(`⚠ not testable: ${m.reason}`);
  } else {
    for (const f of m.files) io.out(`✓ wrote ${f}`);
  }
}

export function renderRed(io: CliIO, r: RedReport): void {
  if (r.kind === "not_testable") {
    io.out(`⚠ not testable: ${r.reason}`);
    return;
  }
  for (const p of r.problems) io.out(`✗ ${p}`);
  for (const run of r.runs) io.out(runLine(run));
  io.out(
    r.ok
      ? "✓ every acceptance test fails for the right reason"
      : "✗ acceptance tests are not proven red",
  );
  if (!r.ok) tails(io, r.runs);
}

export function renderGreen(io: CliIO, r: GreenReport): void {
  for (const p of r.problems) io.out(`✗ ${p}`);
  for (const v of r.violations) {
    io.out(`${v.severity === "block" ? "✗" : "⚠"} integrity ${v.rule}: ${v.path}: ${v.detail}`);
  }
  for (const p of r.restored) io.out(`⚠ restored locked test ${p} (it had been changed)`);
  for (const run of r.runs) io.out(runLine(run));
  io.out(r.ok ? "✓ acceptance tests pass" : "✗ acceptance gate failed");
  if (!r.ok) tails(io, r.runs);
}
