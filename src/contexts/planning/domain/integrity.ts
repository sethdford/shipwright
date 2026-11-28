import { isTestConfigPath, isTestPath } from "./test-path";

/**
 * Guards the tests against the agent that is graded by them. Given the diff from the commit
 * that locked the acceptance tests to the implementation, it lists every change that could
 * make a test suite pass without the behavior being there: editing a locked acceptance test,
 * deleting a test, adding skip/only/todo markers, dropping assertions, or narrowing which
 * tests the runner collects.
 */
export type ChangeStatus = "added" | "modified" | "deleted" | "renamed";

export interface FileChange {
  readonly path: string;
  /** For renames, the path before the change. */
  readonly from?: string;
  readonly status: ChangeStatus;
  readonly added: readonly string[];
  readonly removed: readonly string[];
}

export type IntegrityRule =
  | "acceptance_test_changed"
  | "test_deleted"
  | "test_disabled"
  | "assertions_removed"
  | "test_collection_narrowed"
  | "test_config_changed";

export interface Violation {
  readonly rule: IntegrityRule;
  readonly path: string;
  readonly severity: "block" | "warn";
  readonly detail: string;
}

/** Parses `git diff` output (unified, with rename detection) into one entry per file. */
export function parseDiff(text: string): readonly FileChange[] {
  const changes: FileChange[] = [];
  let cur: ParsedChange | null = null;
  for (const line of text.split("\n")) {
    const head = /^diff --git a\/(.+) b\/(.+)$/.exec(line);
    if (head) {
      if (cur && !modeOnly(cur)) changes.push(cur);
      cur = {
        path: head[2] ?? "",
        status: "modified",
        added: [],
        removed: [],
        mode: false,
        content: false,
      };
    } else if (cur) {
      readLine(cur, line);
    }
  }
  if (cur && !modeOnly(cur)) changes.push(cur);
  return changes.map(({ path, from, status, added, removed }) =>
    from === undefined ? { path, status, added, removed } : { path, from, status, added, removed },
  );
}

interface ParsedChange {
  path: string;
  from?: string;
  status: ChangeStatus;
  added: string[];
  removed: string[];
  /** Saw an `old mode`/`new mode` pair. */
  mode: boolean;
  /** Saw a hunk or a binary change, i.e. the bytes changed. */
  content: boolean;
}

function readLine(cur: ParsedChange, line: string): void {
  if (line.startsWith("new file mode")) cur.status = "added";
  else if (line.startsWith("deleted file mode")) cur.status = "deleted";
  else if (line.startsWith("rename from ")) {
    cur.status = "renamed";
    cur.from = line.slice("rename from ".length);
  } else if (/^(old|new) mode /.test(line)) {
    // Only a regular-file exec bit flip is harmless; any other mode change counts as content.
    if (/^(old|new) mode 100(644|755)$/.test(line)) cur.mode = true;
    else cur.content = true;
  } else if (/^(@@ |Binary files |GIT binary patch)/.test(line)) cur.content = true;
  else if (line.startsWith("+") && !line.startsWith("+++")) cur.added.push(line.slice(1));
  else if (line.startsWith("-") && !line.startsWith("---")) cur.removed.push(line.slice(1));
}

/**
 * Only the executable bit flipped (100644 <-> 100755): the bytes are identical, and suites run as
 * `bash <file>`, so this is no edit. A tool such as `sw-doctor --fix` does it during test runs (#8626).
 */
function modeOnly(c: ParsedChange): boolean {
  return c.status === "modified" && c.mode && !c.content && c.added.length + c.removed.length === 0;
}

const DISABLE =
  /\b(it|test|describe|context|suite)\.(skip|only|todo|skipIf|runIf)\b|\bx(it|describe|test)\s*\(|\bf(it|describe)\s*\(|@pytest\.mark\.(skip|skipif|xfail)|pytest\.(skip|xfail)\s*\(|@unittest\.(skip|expectedFailure)|\bt\.Skip(Now|f)?\s*\(|#\[ignore\]|@(Disabled|Ignore)\b|\bpending\s*\(|\bskip\s*:\s*true/;
const ASSERTION =
  /\b(expect|assert\w*|should)\s*[.(]|\.(to|not)\.|\.to(Be|Equal|StrictEqual|Throw|Match|Contain|Have)\w*\s*\(|assert(_eq|_ne)?!|\bt\.(Error|Errorf|Fatal|Fatalf|Fail)\s*\(|\brequire\.\w+\s*\(|\bself\.assert\w+\s*\(/;
const NARROW =
  /testPathIgnorePatterns|modulePathIgnorePatterns|\bexclude\b|\bignore\b|--ignore|--deselect|testMatch|testRegex|testNamePattern|collect_ignore|norecursedirs|addopts|\bonly\b|bail|passWithNoTests/;

const count = (lines: readonly string[], re: RegExp) => lines.filter((l) => re.test(l)).length;

/** Every integrity finding for the changes since the lock. */
export function checkIntegrity(
  changes: readonly FileChange[],
  locked: readonly string[],
): readonly Violation[] {
  const lockedSet = new Set(locked);
  return changes.flatMap((c) => fileViolations(c, lockedSet));
}

function fileViolations(c: FileChange, locked: ReadonlySet<string>): Violation[] {
  const out: Violation[] = [];
  const v = (rule: IntegrityRule, severity: Violation["severity"], detail: string) =>
    out.push({ rule, path: c.path, severity, detail });
  const before = c.from ?? c.path;
  if (locked.has(before) && c.status !== "added") {
    v("acceptance_test_changed", "block", `locked acceptance test was ${c.status}`);
  }
  if (
    isTestPath(before) &&
    (c.status === "deleted" || (c.status === "renamed" && !isTestPath(c.path)))
  ) {
    v(
      "test_deleted",
      "block",
      c.status === "deleted" ? "test file deleted" : `test moved to non-test path (from ${before})`,
    );
  }
  if (isTestPath(c.path) || isTestPath(before)) {
    const disabled = count(c.added, DISABLE) - count(c.removed, DISABLE);
    if (disabled > 0) v("test_disabled", "block", `${disabled} skip/only/todo marker(s) added`);
    const dropped = count(c.removed, ASSERTION) - count(c.added, ASSERTION);
    if (c.status !== "added" && c.status !== "deleted" && dropped > 0) {
      v("assertions_removed", "block", `${dropped} assertion line(s) removed`);
    }
  }
  if (isTestConfigPath(c.path) || isTestScriptChange(c)) {
    const narrowed = count(c.added, NARROW) > count(c.removed, NARROW);
    if (narrowed)
      v("test_collection_narrowed", "block", "test selection or exclusion settings added");
    else v("test_config_changed", "warn", "file that decides which tests run was changed");
  }
  return out;
}

function isTestScriptChange(c: FileChange): boolean {
  if (!/(^|\/)package\.json$/.test(c.path)) return false;
  const touches = (l: string) => /^\s*"(test(:\w+)?|jest|vitest|mocha)"\s*:/.test(l);
  return c.added.some(touches) || c.removed.some(touches);
}

/** True when any violation blocks. */
export function blocks(violations: readonly Violation[]): boolean {
  return violations.some((v) => v.severity === "block");
}
