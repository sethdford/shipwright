/**
 * Reads one test run. Before implementation an acceptance test must fail for the right
 * reason: an assertion, or the feature it tests not existing yet (a missing module, export,
 * function or attribute; the SWE-bench "fail-to-pass" shape). A test that passes already, does
 * not run, or breaks on its own syntax, a missing test framework or an unrelated error checks
 * nothing, so it is rejected and the writer is told why.
 */
export interface RunOutcome {
  readonly exitCode: number;
  readonly timedOut: boolean;
  readonly output: string;
}

export type RedReason = "assertion" | "missing_feature";
export type NotRedReason =
  | "passed"
  | "timeout"
  | "no_tests"
  | "environment"
  | "test_broken"
  | "not_this_test"
  | "unexplained";

export interface RunVerdict {
  readonly ok: boolean;
  readonly reason: RedReason | NotRedReason | "green";
  /** The output line that decided the verdict, when one did. */
  readonly evidence?: string;
}

type Rule = readonly [RegExp, NotRedReason | RedReason];

const NO_TESTS =
  /no tests? (were )?(found|ran|collected)|collected 0 items|No test files found|no test files|Ran 0 tests|\b0 tests?\b[^\n]*\b0 (passed|failures)|^\s*0 pass\s*\n\s*0 fail/im;

/** Checked in order; the first match decides. */
const FAILURE_RULES: readonly Rule[] = [
  [
    /command not found|ENOENT[^\n]*spawn|No module named '?(pytest|unittest)\b|Cannot find (module|package) ['"](vitest|jest|@jest\/globals|mocha|chai|bun:test|@testing-library\/[\w-]+)['"]|ECONNREFUSED|EADDRINUSE|JavaScript heap out of memory|Killed\s*$/im,
    "environment",
  ],
  [
    /does not provide an export named|Export named ['"]?\w+['"]? not found|has no exported member|error TS(2305|2307|2339|2304|2614|2724)\b/i,
    "missing_feature",
  ],
  [
    /\b(SyntaxError|ParseError|IndentationError|TabError)\b|error TS\d+|Unexpected token|Transform failed|error: Expected .+ but found|Unterminated string|expected expression/i,
    "test_broken",
  ],
  [
    /Cannot find (module|package) ['"]\.{0,2}\/|Module not found|ImportError: cannot import name|ModuleNotFoundError: No module named|has no attribute|NameError: name|is not (a function|a constructor|defined)|undefined: \w+|cannot find (function|value|struct|type|module|crate|symbol)|unresolved import|no (function|method) named|NoMethodError|uninitialized constant|NotImplementedError|not implemented/i,
    "missing_feature",
  ],
  [
    /AssertionError|assert(ion)? ?(failed|error)|\bexpect(ed)?\b[^\n]*\b(to|but|received|got)\b|Expected:|Received:|--- FAIL|\bFAILED\b|panicked at|assert_eq!|AssertionFailedError|Failure:|\(fail\)|✗|✕|\d+ fail(ed|ing|ures?)?\b/i,
    "assertion",
  ],
];

function matchLine(re: RegExp, output: string): string | undefined {
  const m = re.exec(output);
  if (!m) return undefined;
  const start = output.lastIndexOf("\n", m.index) + 1;
  const end = output.indexOf("\n", m.index);
  return output
    .slice(start, end < 0 ? undefined : end)
    .trim()
    .slice(0, 300);
}

/** True when the run names this test: its file name or one of its criterion ids. */
export function mentionsTest(output: string, path: string, criteria: readonly string[]): boolean {
  const base = path.slice(path.lastIndexOf("/") + 1);
  const stem = base.includes(".") ? base.slice(0, base.indexOf(".")) : base;
  if (output.includes(base) || (stem.length >= 4 && output.includes(stem))) return true;
  return criteria.some((c) => new RegExp(`\\b${c}\\b`).test(output));
}

/** The verdict for a run before implementation (it must fail for the right reason). */
export function redVerdict(run: RunOutcome, path: string, criteria: readonly string[]): RunVerdict {
  if (run.timedOut) return { ok: false, reason: "timeout" };
  const noTests = matchLine(NO_TESTS, run.output);
  if (noTests !== undefined) return { ok: false, reason: "no_tests", evidence: noTests };
  if (run.exitCode === 0) return { ok: false, reason: "passed" };
  for (const [re, reason] of FAILURE_RULES) {
    const evidence = matchLine(re, run.output);
    if (evidence === undefined) continue;
    const red = reason === "assertion" || reason === "missing_feature";
    if (red && !mentionsTest(run.output, path, criteria)) {
      return { ok: false, reason: "not_this_test", evidence };
    }
    return red ? { ok: true, reason, evidence } : { ok: false, reason, evidence };
  }
  return { ok: false, reason: "unexplained" };
}

const ZERO_PASSED = /(^|\s)0 pass(ed|es)?\b/m;
const SOME_PASSED = /(^|\s)[1-9]\d* pass(ed|es)?\b/m;

/**
 * The verdict for a run after implementation: it must pass and must have run something. Many
 * runners name only failing files, so a pass is not required to name the test; the same argv
 * already named it when it was proven red.
 */
export function greenVerdict(run: RunOutcome): RunVerdict {
  if (run.timedOut) return { ok: false, reason: "timeout" };
  const noTests = matchLine(NO_TESTS, run.output);
  if (noTests !== undefined) return { ok: false, reason: "no_tests", evidence: noTests };
  if (run.exitCode !== 0) {
    const first = FAILURE_RULES.map(([re]) => matchLine(re, run.output)).find(
      (l) => l !== undefined,
    );
    return { ok: false, reason: "assertion", ...(first ? { evidence: first } : {}) };
  }
  if (ZERO_PASSED.test(run.output) && !SOME_PASSED.test(run.output)) {
    return { ok: false, reason: "no_tests", evidence: "0 tests passed" };
  }
  return { ok: true, reason: "green" };
}

export const REASON_HELP: Readonly<Record<NotRedReason, string>> = {
  passed: "the test already passes, so it does not check the new behavior",
  timeout: "the run timed out",
  no_tests: "the runner found no tests in the file",
  environment: "the run failed before testing anything (missing runner, framework or service)",
  test_broken: "the test file itself does not compile or parse",
  not_this_test:
    "the output never names this test file or its criteria; the runner may have run something else",
  unexplained: "the run failed, but not on an assertion or a missing feature",
};
