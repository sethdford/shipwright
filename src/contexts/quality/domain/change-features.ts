/**
 * Features of a candidate change for the merge verifier. The same features are read from a PR in
 * the repository's history (to learn from) and from a change that is not a PR yet (to score), so a
 * historical PR and a fresh candidate are described the same way. Pure.
 *
 * The hand-picked features come from why the pipeline's own PRs closed unmerged (2026-11-26):
 * run artifacts in the diff, model chatter as the title or summary, "already implemented" runs
 * with no real change, and very large diffs. The execution signals (own tests, cross-tests, rubric)
 * come from the build tournament and are unknown for history.
 */

export interface FileChange {
  readonly path: string;
  readonly additions: number;
  readonly deletions: number;
}

/** Signals the run measured on the candidate. `null` means not measured (always so for history). */
export interface ChangeSignals {
  readonly ownTestsPass: boolean | null;
  /** Share of the other attempts' tests this candidate passes (tournament cross-tests). */
  readonly crossPassRate: number | null;
  /** Weighted share of the issue rubric the candidate meets. */
  readonly rubricScore: number | null;
  /** The prompted critic's probability that the change merges and stays merged. */
  readonly criticProbability: number | null;
}

export interface ChangeSummary {
  readonly title: string;
  readonly body: string;
  readonly files: readonly FileChange[];
  readonly signals: ChangeSignals;
  /** Written by the factory. Every candidate is; in history this separates the two populations. */
  readonly factory: boolean;
}

export const NO_SIGNALS: ChangeSignals = {
  ownTestsPass: null,
  crossPassRate: null,
  rubricScore: null,
  criticProbability: null,
};

export const FEATURES = [
  "factory",
  "size",
  "spread",
  "runArtifacts",
  "noChange",
  "harness",
  "testsAdded",
  "testsWeakened",
  "chatter",
  "conventionalTitle",
  "testsFailing",
  "cross",
  "rubric",
  "critic",
] as const;
export type Feature = (typeof FEATURES)[number];
export type FeatureVector = Readonly<Record<Feature, number>>;

const RUN_ARTIFACT =
  /(^|\/)(\.claude\/(loop-|pipeline-|intelligence-|daemon-|cache|.*\.log$)|loop-state|.*\.jsonl$)/;
const PLAN_ONLY = /^docs\/plans\/.*\.md$|^\.claude\/[^/]*PLAN[^/]*\.md$/i;
const HARNESS =
  /^(\.github\/workflows\/|tools\/arch\/findings-baseline\.json$|biome\.jsonc?$|tsconfig[^/]*\.json$|bunfig\.toml$|vitest\.config|\.eslintrc|lefthook)/;
const TEST_FILE = /(^|\/)(tests?|__tests__)\/|[._-]test\.[a-z]+$|\.spec\.[a-z]+$|-test\.sh$/;
const CONVENTIONAL =
  /^(feat|fix|docs|chore|refactor|test|ci|perf|build|style|release|revert)(\([^)]{1,40}\))?!?: \S/;
/** Model text that ended up as a PR title or summary instead of a description of the change. */
const CHATTER =
  /already (fully )?(implemented|complete|on main|exists)|invalid api key|here'?s (my|what)|i (have|will|can't)|the implementation is|no changes? (were|are) needed/i;

export const isRunArtifact = (path: string): boolean => RUN_ARTIFACT.test(path);
export const isTestFile = (path: string): boolean => TEST_FILE.test(path);

const lines = (f: FileChange): number => f.additions + f.deletions;
const sum = (fs: readonly FileChange[], pick: (f: FileChange) => number): number =>
  fs.reduce((s, f) => s + pick(f), 0);
const flag = (b: boolean): number => (b ? 1 : 0);
const centered = (v: number | null): number => (v === null ? 0 : Math.min(1, Math.max(0, v)) - 0.5);

/** Logit of the critic's probability, clipped and scaled to about [-1.3, 1.3]; 0 when absent. */
function criticFeature(p: number | null): number {
  if (p === null || Number.isNaN(p)) return 0;
  const q = Math.min(0.98, Math.max(0.02, p));
  return Math.log(q / (1 - q)) / 3;
}

function fileFeatures(files: readonly FileChange[]) {
  const real = files.filter((f) => !isRunArtifact(f.path) && !PLAN_ONLY.test(f.path));
  const tests = files.filter((f) => isTestFile(f.path));
  const total = sum(files, lines);
  return {
    size: Math.min(1.5, Math.log10(1 + total) / 4),
    spread: Math.min(files.length, 50) / 50,
    runArtifacts: flag(files.some((f) => isRunArtifact(f.path))),
    noChange: flag(real.length === 0 || sum(real, lines) === 0),
    harness: flag(files.some((f) => HARNESS.test(f.path))),
    testsAdded: flag(tests.some((f) => f.additions > 0)),
    testsWeakened: flag(sum(tests, (f) => f.deletions) > sum(tests, (f) => f.additions)),
  };
}

/** The feature vector of a change. Every value is roughly in [-1.5, 1.5]. */
export function extractFeatures(change: ChangeSummary): FeatureVector {
  const summary = change.body.slice(0, 600);
  const s = change.signals;
  return {
    factory: flag(change.factory),
    ...fileFeatures(change.files),
    chatter: flag(CHATTER.test(change.title) || CHATTER.test(summary)),
    conventionalTitle: flag(CONVENTIONAL.test(change.title)),
    testsFailing: flag(s.ownTestsPass === false),
    cross: centered(s.crossPassRate),
    rubric: centered(s.rubricScore),
    critic: criticFeature(s.criticProbability),
  };
}
