/** A merged pull request as holdout mining needs it. */
export interface MergedPull {
  readonly number: number;
  readonly title: string;
  readonly body: string;
  readonly author: string;
  readonly mergedAtMs: number;
  readonly baseSha: string;
  readonly mergeSha: string;
  readonly files: readonly string[];
}

export interface HoldoutCandidate {
  readonly pull: MergedPull;
  readonly issue: number;
  readonly testFiles: readonly string[];
  readonly testCommands: readonly (readonly string[])[];
}

export interface Rejection {
  readonly pull: number;
  readonly reason: string;
}

const CLOSES = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)\b/i;
const MAX_FILES = 15;
const RUN_OUTPUT = /^(\.claude\/|\.shipwright\/|docs\/plans\/)/;
const BOTS = /\[bot\]$|^dependabot$|^github-actions$/;

/** Test files the harness knows how to run, and the argv that runs each. */
export function testCommandFor(path: string): readonly string[] | null {
  if (/^(src|tools|dashboard)\/.+\.test\.ts$/.test(path)) return ["bun", "test", `./${path}`];
  if (/^scripts\/[A-Za-z0-9._-]+-test\.sh$/.test(path)) return ["bash", path];
  return null;
}

const isTest = (path: string) =>
  testCommandFor(path) !== null || /(^|\/)(tests?|__tests__)\//.test(path);

/** The issue a PR body says it closes, or null. */
export function linkedIssue(body: string): number | null {
  const m = CLOSES.exec(body);
  return m ? Number(m[1]) : null;
}

/**
 * SWE-bench-style mining rules: a merged, human PR that closes an issue, changes both source
 * and runnable tests, and is small enough to be one task. The tests it adds or changes become
 * the hidden oracle; the source change is the gold patch nobody shows the agent.
 */
export function classifyPull(pull: MergedPull): HoldoutCandidate | Rejection {
  const no = (reason: string): Rejection => ({ pull: pull.number, reason });
  if (BOTS.test(pull.author)) return no("bot author");
  const issue = linkedIssue(pull.body);
  if (issue === null) return no("closes no issue");
  if (pull.files.length > MAX_FILES)
    return no(`touches ${pull.files.length} files (max ${MAX_FILES})`);
  if (pull.files.some((f) => RUN_OUTPUT.test(f))) return no("contains run output or plans");
  const tests = pull.files.filter(isTest);
  const source = pull.files.filter((f) => !isTest(f) && !/\.(md|txt)$/.test(f));
  if (source.length === 0) return no("no source change");
  const commands = tests.map(testCommandFor).filter((c): c is readonly string[] => c !== null);
  if (commands.length === 0) return no("no runnable test change");
  return { pull, issue, testFiles: tests, testCommands: commands };
}

/** Paths a unified diff touches (both sides), for resetting them before the test patch. */
export function patchPaths(diff: string): readonly string[] {
  const paths = new Set<string>();
  for (const line of diff.split("\n")) {
    const m = /^(?:---|\+\+\+) (?:a|b)\/(.+)$/.exec(line);
    if (m?.[1]) paths.add(m[1]);
  }
  return [...paths];
}

/** The part of a unified diff (git format) that touches `paths`. */
export function filterDiff(diff: string, paths: readonly string[]): string {
  const keep = new Set(paths);
  const parts = diff.split(/^(?=diff --git )/m);
  return parts
    .filter((part) => {
      const m = /^diff --git a\/(\S+) b\/(\S+)/.exec(part);
      return m !== null && (keep.has(m[1] ?? "") || keep.has(m[2] ?? ""));
    })
    .join("");
}
