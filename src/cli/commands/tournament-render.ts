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
  const v = c.verifier != null ? `, verifier ${pct(c.verifier)}` : "";
  const shadow = c.verifierShadow != null ? `, verifier ${pct(c.verifierShadow)} (shadow)` : "";
  return `${c.id}: score ${pct(c.composite)}, cross-tests ${pct(c.cross)}, rubric ${pct(c.rubric)}${v}${shadow}${votes}${gate}`;
}

const usd = (v: number): string => `$${v.toFixed(2)}`;

type EarlyStop = NonNullable<TournamentReport["earlyStop"]>;

function stopVerdict(e: EarlyStop): string {
  const p = e.probes.find((x) => x.id === e.triggeredBy)?.p;
  const at = p == null ? "" : ` at p=${p.toFixed(2)}`;
  const same = e.sameWinner === null ? "" : `; same winner: ${e.sameWinner ? "yes" : "no"}`;
  const bar = `p>=${e.threshold.toFixed(2)}`;
  if (e.mode === "off") return "not evaluated";
  if (e.mode === "enforce") {
    return e.wouldStopAt === null
      ? `ran all ${e.ran} of ${e.of} attempts; none reached ${bar}`
      : `stopped after ${e.ran} of ${e.of} attempts${at}, leaving ~${usd(e.savedUsd)} of attempt budget unspent${same}`;
  }
  return e.wouldStopAt === null
    ? `would not have stopped early (no attempt reached ${bar})`
    : `would have stopped after ${e.wouldStopAt} of ${e.of} attempts${at}, saving ~${usd(e.savedUsd)}${same}`;
}

/** One or two lines: the early-stop verdict, then any notes (such as why enforce fell back). */
function earlyStopLines(r: TournamentReport, clean: (t: string) => string = (t) => t): string[] {
  const e = r.earlyStop;
  if (!e) return [];
  const line = `Early stop (${e.mode}): ${stopVerdict(e)}`;
  return e.notes.length > 0 ? [line, `  ${e.notes.map(clean).join("; ")}`] : [line];
}

export function renderTournamentText(r: TournamentReport): string {
  const s = r.selection;
  const head = s.winner
    ? `Winner: ${s.winner} (${s.confidence} confidence; ${s.reason})${r.adopted ? ", applied to the current branch" : ""}`
    : `No winner: ${s.reason}`;
  return [
    head,
    `Cost: $${r.costUsd.toFixed(2)}`,
    ...earlyStopLines(r),
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

function earlyStopMarkdown(r: TournamentReport): string[] {
  const lines = earlyStopLines(r, inert);
  return lines.length > 0 ? ["", lines.map((l) => l.trim()).join(" ")] : [];
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
    ...earlyStopMarkdown(r),
  ].join("\n");
}
