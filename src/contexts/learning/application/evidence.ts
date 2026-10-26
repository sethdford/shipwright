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
//   `ERROR ` or `N failed|passed|error` line.
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

/** The text without test-runner output (titles, and the blocks listed above TEST_TITLE). */
export function dropTestTitles(text: string): string {
  const kept: string[] = [];
  let mode: "none" | "mocha" | "jest" | "console" | "panic" | "vitest" | "pytest" = "none";
  for (const line of text.split("\n")) {
    if (mode === "mocha" && /^[ \t]+[^ \t]/.test(line)) {
      // Nested suite lines, then the test title, which ends in `:`.
      if (/:[ \t]*$/.test(line)) mode = "none";
      continue;
    }
    // jest indents the logged message, so a column-0 line also ends its block.
    if (mode === "jest" && /^[ \t]+[^ \t]/.test(line)) continue;
    if (mode === "console" && !BLANK.test(line)) continue;
    if (mode === "panic" && !/^(?:note|error|stack backtrace):/.test(line) && !BLANK.test(line))
      continue;
    if (mode === "vitest" && !/^ ❯ /.test(line) && !BLANK.test(line)) continue;
    if (
      mode === "pytest" &&
      !/^(?:-----|=====|___|FAILED |ERROR |\d+ (?:failed|passed|error))/.test(line)
    )
      continue;
    mode = "none";
    if (JEST_CONSOLE.test(line)) mode = "jest";
    else if (VITEST_OUTPUT.test(line)) mode = "console";
    else if (CARGO_PANIC.test(line)) mode = "panic";
    else if (VITEST_FAIL.test(line)) mode = "vitest";
    else if (PYTEST_CAPTURED.test(line)) mode = "pytest";
    else if (MOCHA_TITLE.test(line)) mode = "mocha";
    else if (!TEST_TITLE.test(line)) kept.push(line);
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
