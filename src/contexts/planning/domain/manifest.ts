import { z } from "zod";
import { testPathProblem } from "./test-path";

/**
 * The acceptance contract for one issue: numbered criteria and the new test files that
 * check them. Each criterion is covered by at least one test, and each test names (in its
 * source, normally in the test title) every criterion it claims, so a failure points back
 * to a sentence of the issue.
 */
export interface Criterion {
  readonly id: string;
  readonly text: string;
}

export interface AcceptanceTest {
  readonly path: string;
  readonly criteria: readonly string[];
}

export type AcceptanceManifest =
  | {
      readonly kind: "tests";
      readonly criteria: readonly Criterion[];
      readonly tests: readonly AcceptanceTest[];
      /** Runner argv the test writer proposed, with {file}; used only when nothing better is known. */
      readonly run?: readonly string[];
    }
  | { readonly kind: "not_testable"; readonly reason: string };

export const MANIFEST_LIMITS = { criteria: 20, tests: 20, fileBytes: 100_000, reason: 500 };

const id = z.string().regex(/^AC-\d{1,3}$/);
const raw = z.strictObject({
  criteria: z
    .array(z.strictObject({ id, text: z.string().trim().min(1).max(500) }))
    .max(MANIFEST_LIMITS.criteria)
    .optional(),
  tests: z
    .array(z.strictObject({ path: z.string(), criteria: z.array(id).min(1).max(20) }))
    .max(MANIFEST_LIMITS.tests)
    .optional(),
  run: z.array(z.string().min(1).max(200)).min(1).max(20).optional(),
  not_testable: z.string().trim().min(1).max(MANIFEST_LIMITS.reason).optional(),
});

export type ManifestResult =
  | { readonly ok: true; readonly manifest: AcceptanceManifest }
  | { readonly ok: false; readonly problems: readonly string[] };

/** Parses and checks a manifest. Every problem is listed, so the writer can fix them in one retry. */
export function parseManifest(json: string): ManifestResult {
  let value: unknown;
  try {
    value = JSON.parse(json);
  } catch {
    return { ok: false, problems: ["acceptance.json is not valid JSON"] };
  }
  const parsed = raw.safeParse(value);
  if (!parsed.success) {
    const problems = parsed.error.issues.map(
      (i) => `${i.path.join(".") || "manifest"}: ${i.message}`,
    );
    return { ok: false, problems };
  }
  const m = parsed.data;
  if (m.not_testable !== undefined) {
    if ((m.tests?.length ?? 0) > 0) {
      return {
        ok: false,
        problems: ["not_testable and tests are exclusive: give one or the other"],
      };
    }
    return { ok: true, manifest: { kind: "not_testable", reason: m.not_testable } };
  }
  const criteria = m.criteria ?? [];
  const tests = m.tests ?? [];
  const problems = contractProblems(criteria, tests);
  if (problems.length > 0) return { ok: false, problems };
  return {
    ok: true,
    manifest: { kind: "tests", criteria, tests, ...(m.run ? { run: m.run } : {}) },
  };
}

function contractProblems(
  criteria: readonly Criterion[],
  tests: readonly AcceptanceTest[],
): string[] {
  const problems: string[] = [];
  if (criteria.length === 0)
    problems.push("criteria: at least one acceptance criterion is required");
  if (tests.length === 0) problems.push("tests: at least one test file is required");
  const ids = new Set<string>();
  for (const c of criteria) {
    if (ids.has(c.id)) problems.push(`criteria: ${c.id} is listed twice`);
    ids.add(c.id);
  }
  const paths = new Set<string>();
  const covered = new Set<string>();
  for (const t of tests) {
    const problem = testPathProblem(t.path);
    if (problem) problems.push(`tests: ${t.path} cannot hold an acceptance test (${problem})`);
    if (paths.has(t.path)) problems.push(`tests: ${t.path} is listed twice`);
    paths.add(t.path);
    for (const c of t.criteria) {
      if (!ids.has(c)) problems.push(`tests: ${t.path} names unknown criterion ${c}`);
      covered.add(c);
    }
  }
  for (const c of ids) if (!covered.has(c)) problems.push(`criteria: ${c} has no test`);
  return problems;
}

/**
 * Traceability: each test file must mention every criterion it claims (for example in a test
 * title like "AC-2: rejects an expired token"). Returns the missing pairs.
 */
export function untracedCriteria(test: AcceptanceTest, content: string): readonly string[] {
  return test.criteria.filter((c) => !new RegExp(`\\b${c}\\b`).test(content));
}
