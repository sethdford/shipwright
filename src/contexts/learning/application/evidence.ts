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
const GH_PREFIX = /^[^\t\n]*\t[^\t\n]*\t\uFEFF?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z ?/;
// A loop commit subject, `[branch sha] loop: ...`. Its branch name comes from issue titles.
const LOOP_COMMIT = /^\[[^\]\n]+\][ \t]*loop:/;
// Model-written analysis and pipeline progress markers. Their prose is not evidence of what failed.
// Written the same way as the awk in bash (_DAEMON_DROP_PROSE): any first token, no counted or Unicode classes.
const MODEL_PROSE =
  /^[ \t]*(?:[^ \t]+[ \t]+)?(?:failure analyzed|failure diagnosis|analyzing failure)(?:[^a-z0-9_]|$)|^[ \t]*[^ \t]*[ \t]*▸/i;

// Test-runner output (#8696). A test's title and its console output are written by whoever wrote the test,
// so "✕ API Error: 401 when token missing" or "(fail) not logged in" says nothing about why the run failed.
// A small explicit list, the same in bash (daemon-failure.sh, _DAEMON_DROP_TEST_OUTPUT):
// - bun `(fail) `, `(pass) `, `(skip) `, `(todo) `; vitest/node:test/jest `✕ ✓ √ ✔ ✖` and a space;
//   jest's `●` header and vitest's `×` result, indented (a column-0 `● ` is Claude Code's, a column-0 `× ` is
//   Shipwright's error glyph, and both are kept);
// - mocha's indented `  1) suite`, and the indented suite lines after it up to the title ending in `:`;
// - a jest `console.log|error|warn|info|debug` header and its indented lines, or a vitest `stderr | `/`stdout | `
//   header up to a blank line;
// - a cargo `thread '...' panicked at` line and its message, up to a blank, `note:` or `error:` line;
// - a vitest ` FAIL  file > test` or ` FAIL  file [ file ]` header, or a `⎯⎯ Unhandled Rejection|Error` header,
//   and the error under it, up to a blank or ` ❯ ` frame line;
// - a pytest `----- Captured stdout|stderr|log` section, up to the next `-----`, `=====`, `___`, `FAILED `,
//   `ERROR path::test` or `N failed|passed|error` line.
// - every block also ends at a gh step boundary (a runner's output never spans steps). Nothing else that is
//   inside a block ends it early: an auth-shaped line later in a block is routine negative-path test output.
// Literal glyphs, never a character class, so both locales agree.
// Linear patterns (a single leading run, no nested repetition), written the same way as the awk in bash.
const TEST_TITLE =
  /^[ \t]*(?:\((?:fail|pass|skip|todo)\) |(?:✕|✓|√|✔|✖) )|^[ \t]+(?:●|×) |^[ \t]+\d+\) /;
const MOCHA_TITLE = /^[ \t]+\d+\) /;
const JEST_CONSOLE = /^[ \t]*console\.(?:log|error|warn|info|debug)[ \t]*$/;
const VITEST_OUTPUT = /^(?:stderr|stdout) \| /;
const CARGO_PANIC = /^thread '[^'\n]*' panicked at /;
const VITEST_FAIL = /^ ?FAIL {2}[^ \t].* (?:> |\[ )|^(?:⎯)+ Unhandled (?:Rejection|Error)/;
const PYTEST_CAPTURED = /^-----+ Captured (?:stdout|stderr|log) /;
const BLANK = /^[ \t]*$/;

// A GitHub Actions step boundary ends any block: a runner's output never spans steps (#8715).
const STEP_BOUNDARY = /^##\[(?:group|endgroup|error)\]|^::error/;
type Mode = "none" | "mocha" | "jest" | "console" | "panic" | "vitest" | "pytest";

const PYTEST_END = /^(?:-----|=====|___|FAILED |ERROR [^ \t]+::|\d+ (?:failed|passed|error))/;

/** Whether `line` is still inside the open block `mode` (mocha's title line, which ends it, counts as inside). */
function insideBlock(mode: Mode, line: string): boolean {
  switch (mode) {
    case "mocha":
    case "jest":
      // Indented lines; jest indents the logged message, so a column-0 line ends its block.
      return /^[ \t]+[^ \t]/.test(line);
    case "console":
      return !BLANK.test(line);
    case "panic":
      return !/^(?:note|error|stack backtrace):/.test(line) && !BLANK.test(line);
    case "vitest":
      return !/^ ❯ /.test(line) && !BLANK.test(line);
    case "pytest":
      return !PYTEST_END.test(line);
    default:
      return false;
  }
}

/** The block a header line opens, "title" for a dropped title line, or "none" for a line to keep. */
function opens(line: string): Mode | "title" {
  if (JEST_CONSOLE.test(line)) return "jest";
  if (VITEST_OUTPUT.test(line)) return "console";
  if (CARGO_PANIC.test(line)) return "panic";
  if (VITEST_FAIL.test(line)) return "vitest";
  if (PYTEST_CAPTURED.test(line)) return "pytest";
  if (MOCHA_TITLE.test(line)) return "mocha";
  return TEST_TITLE.test(line) ? "title" : "none";
}

/** The text without test-runner output (titles, and the blocks listed above TEST_TITLE). */
export function dropTestTitles(text: string): string {
  const kept: string[] = [];
  let mode: Mode = "none";
  for (const line of text.split("\n")) {
    if (mode !== "none" && STEP_BOUNDARY.test(line)) mode = "none";
    if (insideBlock(mode, line)) {
      // mocha's nested suite lines end with the test title, which ends in `:`.
      if (mode === "mocha" && /:[ \t]*$/.test(line)) mode = "none";
      continue;
    }
    const next = opens(line);
    mode = next === "title" ? "none" : next;
    if (next === "none") kept.push(line);
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
