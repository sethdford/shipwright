import type { AgentFailureKind } from "../../../shared/kernel/ports";

// Failure classes (spec §6.2 error fingerprinting). Pure: F1 allows importing shared/kernel types.
export const FAILURE_CLASSES = [
  "auth",
  "invalid_input",
  "environment",
  "transient",
  "budget",
  "max_turns",
  "refusal",
  "schema",
  "truncated",
  "timeout",
  "execution",
  "contamination",
  "unknown",
] as const;
export type FailureClass = (typeof FAILURE_CLASSES)[number];

export interface FailureEvidence {
  /** The typed agent failure kind when the caller has one. It always wins over text. */
  readonly kind?: AgentFailureKind;
  /** Log or error text, for example the tail of a run log. */
  readonly text?: string;
}

// Exhaustive over AgentFailureKind: a new kind fails the typecheck until it is mapped here.
const KIND_CLASS: Readonly<Record<AgentFailureKind, FailureClass>> = {
  auth: "auth",
  transient: "transient",
  budget: "budget",
  max_turns: "max_turns",
  refusal: "refusal",
  schema: "schema",
  truncated: "truncated",
  timeout: "timeout",
  execution: "execution",
  aborted: "execution",
};

// Error lines: only these lines are searched by rules scoped to "error" (anchoring, B6).
const ERROR_LINE = /error|fail|fatal|exception|::error::|enoent|eacces|not found|lockfile/i;

interface Rule {
  readonly pattern: RegExp;
  readonly cls: FailureClass;
  /** "error" rules search error lines only; "any" rules search the whole text. */
  readonly scope: "any" | "error";
}

// First match wins. Auth comes first: retrying an auth failure cannot help, so a rate-limit line
// in the same log must not mask it. The bare token variable name is deliberately not a rule.
const RULES: readonly Rule[] = [
  {
    // Checked first: a contaminated run's other symptoms (auth, rate limit) are side effects of the
    // contamination, and a retry would repeat real side effects. Signals: the test-gate refusal
    // printed by sw-e2e-integration-test.sh (PR #8610), or a CONTAMINATION line the loop records when
    // it finds .claude/pipeline-state.md missing or the branch switched mid-run.
    pattern:
      /refusing to run inside a build-loop test gate|^CONTAMINATION: (pipeline-state-missing|branch-switched)/im,
    cls: "contamination",
    scope: "any",
  },
  {
    pattern:
      /authentication[ _]failed|invalid api key|api error: 401|oauth token (is )?(expired|invalid)|not logged in|unauthorized/i,
    cls: "auth",
    scope: "any",
  },
  {
    pattern: /issue not found|api error: 404|no body|could not resolve|issue.*does not exist/i,
    cls: "invalid_input",
    scope: "any",
  },
  {
    pattern:
      /command not found|enoent.*(node_modules|\.bin|tsconfig|package\.json)|eacces.*(node_modules|\.bin|\.cache)|error: lockfile|lockfile is frozen|could not (install|resolve) (dependencies|packages)/i,
    cls: "environment",
    scope: "error",
  },
  {
    pattern:
      /rate.?limit|overloaded|api error: (429|5\d\d)|econnreset|etimedout|socket hang up|service unavailable|econnrefused|eai_again/i,
    cls: "transient",
    scope: "any",
  },
];

export function errorLines(text: string): string {
  return text
    .split("\n")
    .filter((line) => ERROR_LINE.test(line))
    .join("\n");
}

/** The last line that looks like an error; the last non-empty line when there is none. */
export function lastErrorLine(text: string): string {
  const lines = text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "");
  const errors = lines.filter((line) => ERROR_LINE.test(line));
  return errors.at(-1) ?? lines.at(-1) ?? "";
}

export function classifyFailure(evidence: FailureEvidence): FailureClass {
  if (evidence.kind !== undefined) return KIND_CLASS[evidence.kind];
  const text = evidence.text ?? "";
  for (const rule of RULES) {
    const haystack = rule.scope === "error" ? errorLines(text) : text;
    if (rule.pattern.test(haystack)) return rule.cls;
  }
  return "unknown";
}

/** FNV-1a, 32-bit: a pure, dependency-free hash for grouping identical failures. */
export function fnv1a(input: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

/** Groups identical failures: the normalised last error line, not the whole tail. */
export function failureFingerprint(cls: FailureClass, text: string): string {
  const normalised = lastErrorLine(text)
    .toLowerCase()
    .replace(/\/[^\s'":]+/g, "<path>")
    .replace(/\d{4}-\d{2}-\d{2}t?[\d:.z+-]*/g, "<time>")
    .replace(/0x[0-9a-f]+|\b[0-9a-f]{7,40}\b/g, "<hex>")
    .replace(/\d+/g, "0")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 200);
  return `${cls}:${fnv1a(normalised)}`;
}
