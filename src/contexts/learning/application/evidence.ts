// Bounds, normalizes and cleans the text a classifier sees. This is the only place input is
// prepared, so the domain rules can assume short, plain-text, bounded lines.

/** Matches bash's `tail -200` in daemon-failure.sh (classify_failure). */
export const MAX_EVIDENCE_LINES = 200;
/** A single line longer than this is truncated. A 1 MB JSON line must not reach the regexes whole. */
export const MAX_EVIDENCE_LINE_CHARS = 4096;

// Colour codes. helpers.sh only strips them when NO_COLOR is set, so real logs carry them.
const ESC = String.fromCharCode(27);
const ANSI = new RegExp(`${ESC}\\[[0-9;?]*[A-Za-z]`, "g");
// `gh run view --log-failed` prefixes every line with `job<TAB>step<TAB>timestamp`, sometimes with a BOM.
const GH_PREFIX = /^[^\t\n]*\t[^\t\n]*\t﻿?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z ?/;
// A loop commit subject, `[branch sha] loop: ...`. Its branch name comes from issue titles.
const LOOP_COMMIT = /^\[[^\]]{1,200}\]\s*loop:/;
// Model-written analysis and pipeline progress markers. Their prose is not evidence of what failed.
const MODEL_PROSE =
  /^\s*(?:\S{1,3}\s+)?(?:Failure analyzed|Failure diagnosis|Analyzing failure)\b|^\s*\S{0,3}\s*▸/i;

/** Plain text of one line: colour codes, the gh prefix and a trailing CR removed. */
export function normalizeLine(line: string): string {
  return line.replace(ANSI, "").replace(GH_PREFIX, "").replace(/\r$/, "");
}

/**
 * Last MAX_EVIDENCE_LINES lines, each cut to MAX_EVIDENCE_LINE_CHARS, then normalized, then with
 * model prose and loop commit lines dropped. Normalization runs after the cut, so the regexes never
 * see more than a bounded line.
 */
export function boundEvidence(text: string): string {
  return text
    .split("\n")
    .slice(-MAX_EVIDENCE_LINES)
    .map((line) => normalizeLine(line.slice(0, MAX_EVIDENCE_LINE_CHARS)))
    .filter((line) => !MODEL_PROSE.test(line) && !LOOP_COMMIT.test(line))
    .join("\n");
}
