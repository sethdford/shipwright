import { accept, isRecord, type Parsed, reject } from "./parsed";

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

/** A non-merge commit on the default branch, for repos whose fixes land without a PR. */
export interface DirectCommit {
  readonly sha: string;
  readonly parentSha: string;
  readonly message: string;
  readonly author: string;
  readonly committedAtMs: number;
  readonly files: readonly string[];
}

/** The runnable tests a change adds or edits: the hidden oracle. */
export interface OracleFiles {
  readonly testFiles: readonly string[];
  readonly testCommands: readonly (readonly string[])[];
}

export interface HoldoutCandidate extends OracleFiles {
  readonly pull: MergedPull;
  /** The issue the PR closes, or null when the problem statement is curated. */
  readonly issue: number | null;
}

export interface Rejection {
  /** `#123` for a PR, the short sha for a commit. */
  readonly ref: string;
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
 * The file rules every holdout change must meet: small enough to be one task, no run output,
 * and both a source change and a runnable test change. Returns the oracle or the reason.
 */
export function classifyFiles(files: readonly string[]): OracleFiles | string {
  if (files.length > MAX_FILES) return `touches ${files.length} files (max ${MAX_FILES})`;
  if (files.some((f) => RUN_OUTPUT.test(f))) return "contains run output or plans";
  const tests = files.filter(isTest);
  const source = files.filter((f) => !isTest(f) && !/\.(md|txt)$/.test(f));
  if (source.length === 0) return "no source change";
  const commands = tests.map(testCommandFor).filter((c): c is readonly string[] => c !== null);
  if (commands.length === 0) return "no runnable test change";
  return { testFiles: tests, testCommands: commands };
}

/**
 * SWE-bench-style mining rules: a merged, human PR that closes an issue (or has a curated
 * problem statement), changes both source and runnable tests, and is small enough to be one
 * task. The tests it adds or changes become the hidden oracle; the source change is the gold
 * patch nobody shows the agent.
 */
export function classifyPull(pull: MergedPull, curated = false): HoldoutCandidate | Rejection {
  const no = (reason: string): Rejection => ({ ref: `#${pull.number}`, reason });
  if (BOTS.test(pull.author)) return no("bot author");
  const issue = linkedIssue(pull.body);
  if (issue === null && !curated) return no("closes no issue");
  const files = classifyFiles(pull.files);
  if (typeof files === "string") return no(files);
  return { pull, issue, ...files };
}

/**
 * The same rules for a direct commit. A commit message describes the fix, not the problem, so a
 * commit is a candidate only with a curated problem statement (`curated`); without one the
 * rejection says so, which is the list to curate from.
 */
export function classifyCommit(c: DirectCommit, curated: boolean): OracleFiles | Rejection {
  const no = (reason: string): Rejection => ({ ref: c.sha.slice(0, 7), reason });
  if (BOTS.test(c.author)) return no("bot author");
  const files = classifyFiles(c.files);
  if (typeof files === "string") return no(files);
  if (!curated) return no(`needs a curated problem: ${c.message.split("\n")[0]?.slice(0, 100)}`);
  return files;
}

/** The task id of a mined commit. */
export const commitTaskId = (sha: string) => `c-${sha.slice(0, 10)}`;

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

const MAX_PROBLEM = 20_000;

/**
 * A curated problem file: `{ "<task id>": "<problem statement>" }`. A statement says what is
 * wrong or missing as a user would report it, never how the gold commit fixes it.
 */
export function parseProblems(raw: unknown): Parsed<Readonly<Record<string, string>>> {
  if (!isRecord(raw)) return reject("problems must be an object of task id to statement");
  const out: Record<string, string> = {};
  for (const [id, text] of Object.entries(raw)) {
    if (typeof text !== "string" || text.trim().length < 40 || text.length > MAX_PROBLEM)
      return reject(`problem ${id} must be a statement of 40 to ${MAX_PROBLEM} chars`);
    out[id] = text.trim();
  }
  return accept(out);
}
