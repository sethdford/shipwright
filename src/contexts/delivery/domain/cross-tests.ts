/**
 * The cross-validation matrix (TEX, 2026): every candidate's tests run against every candidate's
 * patch. Attempts share only pass/fail, never code, so their errors stay independent. A test suite
 * counts as evidence only when its own author's patch passes it: a suite that fails its own patch
 * is more likely wrong than the other patches.
 */

export type Cell = "pass" | "fail" | "skip";

/** `cells[p][s]` is the result of candidate `s`'s tests on candidate `p`'s patch. */
export interface TestMatrix {
  readonly ids: readonly string[];
  readonly cells: readonly (readonly Cell[])[];
}

/** Indexes of the suites that are evidence: the author's own patch passes them. */
export function validSuites(m: TestMatrix): number[] {
  return m.ids.map((_, s) => s).filter((s) => m.cells[s]?.[s] === "pass");
}

/**
 * Share of the *other* candidates' valid suites that patch `p` passes, or null when there are none
 * to judge by (a single candidate, or no other candidate wrote tests).
 */
export function crossPassRate(m: TestMatrix, p: number): number | null {
  const suites = validSuites(m).filter((s) => s !== p && m.cells[p]?.[s] !== "skip");
  if (suites.length === 0) return null;
  const passed = suites.filter((s) => m.cells[p]?.[s] === "pass").length;
  return passed / suites.length;
}

/** The matrix as a small text table for the report: rows are patches, columns are test suites. */
export function renderMatrix(m: TestMatrix): string {
  const mark: Record<Cell, string> = { pass: "✓", fail: "✗", skip: "·" };
  const head = ["patch \\ tests", ...m.ids].join(" | ");
  const rows = m.ids.map((id, p) =>
    [id, ...m.ids.map((_, s) => mark[m.cells[p]?.[s] ?? "skip"])].join(" | "),
  );
  return [head, ...rows].join("\n");
}

const TEST_PATH = [
  /(^|\/)(test|tests|__tests__|spec|specs)\//,
  /\.(test|spec)\.[a-z0-9]+$/i,
  /_test\.(go|py|rb|exs?)$/,
  /(^|\/)test_[^/]+\.py$/,
  /-test\.sh$/,
];

/** True for paths that conventionally hold tests in JS/TS, Python, Go, Ruby, Elixir and bash repos. */
export const isTestPath = (path: string): boolean => TEST_PATH.some((re) => re.test(path));
