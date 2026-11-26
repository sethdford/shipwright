import { renderMatrix, type TournamentReport } from "../../contexts/delivery";

const pct = (v: number | null): string => (v === null ? "—" : `${Math.round(v * 100)}%`);

function attemptLine(a: TournamentReport["attempts"][number]): string {
  const tests = a.ownTests === null ? "not run" : a.ownTests.passed ? "pass" : "fail";
  const files = a.snapshot?.files.length ?? 0;
  const note = a.note ? `; ${a.note}` : "";
  return `${a.id}: ${files} file(s), tests ${tests}, $${a.costUsd.toFixed(2)}${note}`;
}

function candidateLine(c: TournamentReport["candidates"][number]): string {
  const votes = c.votes > 1 ? ` (same patch from ${c.members.join(", ")})` : "";
  const gate = c.ownTestsPass ? "" : " [failed own tests]";
  return `${c.id}: score ${pct(c.composite)}, cross-tests ${pct(c.cross)}, rubric ${pct(c.rubric)}${votes}${gate}`;
}

export function renderTournamentText(r: TournamentReport): string {
  const s = r.selection;
  const head = s.winner
    ? `Winner: ${s.winner} (${s.confidence} confidence; ${s.reason})${r.adopted ? ", applied to the current branch" : ""}`
    : `No winner: ${s.reason}`;
  return [
    head,
    `Cost: $${r.costUsd.toFixed(2)}`,
    "",
    "Attempts:",
    ...r.attempts.map((a) => `  ${attemptLine(a)}`),
    "",
    "Candidates:",
    ...(r.candidates.length > 0 ? r.candidates.map((c) => `  ${candidateLine(c)}`) : ["  none"]),
    ...(r.notes.length > 0 ? ["", "Notes:", ...r.notes.map((n) => `  ${n}`)] : []),
  ].join("\n");
}

/** Model text going into a PR body: no HTML, no @-mentions, one line per item. */
const inert = (text: string): string =>
  text
    .replace(/[<>]/g, "")
    .replace(/@/g, "@\u200b")
    .replace(/\s*\n\s*/g, " ")
    .trim();

function judgeSection(r: TournamentReport): string[] {
  const j = r.judge?.judgement;
  if (!j) return [];
  const risks = j.consensus.map(
    (c) => `- ${c.defect ? "⚠" : "✓"} ${inert(c.claim)}${c.note ? `: ${inert(c.note)}` : ""}`,
  );
  return [
    "",
    "**Judge (blind, group-wise):**",
    "",
    inert(j.reasons),
    ...(risks.length ? ["", "Shared assumptions checked:", ...risks] : []),
  ];
}

function matrixSection(r: TournamentReport): string[] {
  if (!r.matrix) return [];
  const title = "Cross-test matrix (rows: patch, columns: whose tests):";
  return ["", title, "", "```", renderMatrix(r.matrix), "```"];
}

function rubricSection(r: TournamentReport): string[] {
  if (!r.rubric) return [];
  const lines = r.rubric.criteria.map(
    (c) => `- [${c.id}] (${c.axis}, weight ${c.weight}) ${inert(c.text)}`,
  );
  return ["", "<details><summary>Rubric</summary>", "", ...lines, "", "</details>"];
}

function candidateRows(r: TournamentReport): string[] {
  const rows = r.candidates.map((c) =>
    [
      c.members.join(", "),
      pct(c.composite),
      pct(c.cross),
      pct(c.rubric),
      c.ownTestsPass ? "pass" : "fail",
    ].join(" | "),
  );
  const head = [
    "| Candidate | Score | Cross-tests | Rubric | Own tests |",
    "|---|---|---|---|---|",
  ];
  return [...head, ...rows.map((row) => `| ${row} |`)];
}

/** A section for the PR body: how the winning patch was chosen and how sure the factory is. */
export function renderTournamentMarkdown(r: TournamentReport): string {
  const s = r.selection;
  const margin = s.margin === null ? "" : `, lead ${pct(s.margin)}`;
  const verdict = s.winner
    ? `Chosen: **${s.winner}** from ${r.attempts.length} independent attempts. Confidence: **${s.confidence}** (${s.reason}${margin}).`
    : `No attempt was good enough: ${s.reason}.`;
  return [
    "## Tournament",
    "",
    verdict,
    "",
    ...candidateRows(r),
    ...matrixSection(r),
    ...rubricSection(r),
    ...judgeSection(r),
    "",
    `Tournament cost: $${r.costUsd.toFixed(2)}.`,
  ].join("\n");
}
