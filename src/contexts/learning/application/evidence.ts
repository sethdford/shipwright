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

// Test-runner output (#8696). A test's title and its console output are written by whoever wrote the test,
// so "✕ API Error: 401 when token missing" or "(fail) not logged in" says nothing about why the run failed.
// A small explicit list, the same in bash (daemon-failure.sh, _DAEMON_DROP_TEST_OUTPUT):
// - bun `(fail) `, `(pass) `, `(skip) `, `(todo) `; vitest/node:test/jest `✕ ✓ × √ ✔ ✖` and a space;
//   jest's failure header `●` and a space, indented (Claude Code prints `● ` at column 0, which is kept);
// - mocha's indented `  1) suite`, and the indented suite lines after it up to the title ending in `:`;
// - a jest `console.log|error|warn|info|debug` header and every line after it up to a blank line.
// Literal glyphs, never a character class, so both locales agree.
// Linear patterns (a single leading run, no nested repetition), written the same way as the awk in bash.
const TEST_TITLE =
  /^[ \t]*(?:\((?:fail|pass|skip|todo)\) |(?:✕|✓|×|√|✔|✖) )|^[ \t]+● |^[ \t]+\d+\) /;
const MOCHA_TITLE = /^[ \t]+\d+\) /;
const JEST_CONSOLE = /^[ \t]*console\.(?:log|error|warn|info|debug)[ \t]*$/;

/** The text without test-runner output (titles, mocha title blocks, jest console blocks). */
export function dropTestTitles(text: string): string {
  const kept: string[] = [];
  let mode: "none" | "mocha" | "console" = "none";
  for (const line of text.split("\n")) {
    if (mode === "mocha" && /^[ \t]+[^ \t]/.test(line)) {
      // Nested suite lines, then the test title, which ends in `:`.
      if (/:[ \t]*$/.test(line)) mode = "none";
      continue;
    }
    if (mode === "console" && !/^[ \t]*$/.test(line)) continue;
    mode = "none";
    if (JEST_CONSOLE.test(line)) {
      mode = "console";
      continue;
    }
    if (TEST_TITLE.test(line)) {
      if (MOCHA_TITLE.test(line)) mode = "mocha";
      continue;
    }
    kept.push(line);
  }
  return kept.join("\n");
}

// A byte-order mark at the start of a line, and the line breaks JavaScript's `m` flag honours but grep does
// not: a lone CR (progress bars), U+2028 and U+2029. They become real line breaks, as in bash.
const BOM = /^\uFEFF/;
const INNER_BREAK = /\r|\u2028|\u2029/g;

/** Plain text of one line: colour codes, the gh prefix, a BOM and a trailing CR removed. */
export function normalizeLine(line: string): string {
  return line.replace(ANSI, "").replace(GH_PREFIX, "").replace(/\r$/, "").replace(BOM, "");
}

/**
 * Last MAX_EVIDENCE_LINES lines, each cut to MAX_EVIDENCE_LINE_CHARS, then normalized, then with
 * model prose and loop commit lines dropped. Normalization runs after the cut, so the regexes never
 * see more than a bounded line.
 */
export function boundEvidence(text: string): string {
  // A trailing newline ends the last line; it does not start an empty one (as `tail -200` counts).
  const lines = text.split("\n");
  if (lines.length > 1 && lines.at(-1) === "") lines.pop();
  return lines
    .slice(-MAX_EVIDENCE_LINES)
    .flatMap((line) => normalizeLine(line.slice(0, MAX_EVIDENCE_LINE_CHARS)).split(INNER_BREAK))
    .filter((line) => !MODEL_PROSE.test(line) && !LOOP_COMMIT.test(line))
    .join("\n");
}
