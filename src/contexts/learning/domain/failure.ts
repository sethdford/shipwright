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

// Error-like lines. Rules scoped to "error" search only these lines. Deliberately wider than
// "error|fail" so that a bare API message such as "invalid x-api-key" is still error-like.
const ERROR_LINE =
  /error|fail|fatal|exception|::error::|enoent|eacces|not found|lockfile|invalid|unauthori[sz]ed|forbidden|denied|overloaded|rate[ _-]?limit|timed? ?out|\b[45]\d\d\b|econn|etimedout|socket hang up|unavailable|authentication|not logged in|refus|contaminat|expired|revoked|could not resolve|does not exist|claude_code_oauth_token/i;

interface Rule {
  readonly pattern: RegExp;
  readonly cls: FailureClass;
  /** "error" rules search error-like lines only; "any" rules search the whole text. */
  readonly scope: "any" | "error";
}

// Every quantifier is bounded (`[^\n]{0,200}`, never `.*`): an unbounded `.*` on a long line
// backtracks super-linearly (ReDoS). A guard test in failure.test.ts enforces this.
// First match wins. Auth comes first: retrying an auth failure cannot help, so a rate-limit line
// in the same log must not mask it. The bare token variable name is deliberately not a rule.
const RULES: readonly Rule[] = [
  {
    // Checked first: a contaminated run's other symptoms (auth, rate limit) are side effects of the
    // contamination, and a retry would repeat real side effects. Signals: the test-gate refusal
    // printed by sw-e2e-integration-test.sh (PR #8610), or a CONTAMINATION line the loop records when
    // it finds .claude/pipeline-state.md missing or the branch switched mid-run.
    // Anchored on the whole structured line, so `echo "CONTAMINATION: x"` in test output does not match, and
    // scoped to error lines. The refusal is the line sw-e2e-integration-test.sh prints; the reason is a fixed list.
    pattern:
      /^[^A-Za-z0-9]{0,4}Skipping integration tests: refusing to run inside a build-loop test gate[ \t]{0,20}$|^CONTAMINATION: (?:pipeline-state-missing|branch-switched)(?:[ \t]|$)/im,
    cls: "contamination",
    scope: "error",
  },
  {
    pattern:
      /authentication[ _]failed|authentication_error|invalid api key|invalid x-api-key|api error: 401|oauth token (is |has )?(expired|invalid|revoked)|not logged in|unauthorized/i,
    cls: "auth",
    // Error lines only: the same selection as the other escalation rules. Bare words in prose are not auth.
    scope: "error",
  },
  {
    // The sandbox warning the Claude CLI prints when bubblewrap or socat is missing. It is setup,
    // not auth: a run whose only symptom is this line is environment (retried once).
    pattern: /sandbox is enabled but dependencies are missing/i,
    cls: "environment",
    scope: "any",
  },
  {
    pattern:
      /command not found|enoent[^\n]{0,200}(node_modules|\.bin|tsconfig|package\.json)|eacces[^\n]{0,200}(node_modules|\.bin|\.cache)|error: lockfile|lockfile is frozen|could not (install|resolve) (dependencies|packages)/i,
    cls: "environment",
    scope: "error",
  },
  {
    // DNS and host lookup failures are the network, not the input. Checked before invalid_input.
    pattern: /\bcould not resolve host\b|\bENOTFOUND\b/i,
    cls: "environment",
    scope: "any",
  },
  {
    // Structured signals only. Free text such as "rate limit" or "overloaded" is NOT transient:
    // model prose, branch names and test names can say those words. Bash matches them; this is a
    // deliberate difference (see classify-parity.json).
    pattern:
      /\bHTTP(?:\/\d(?:\.\d)?)?\s+(?:429|5\d\d)\b|\bstatus"?\s*:\s*"?(?:429|5\d\d)\b|\b503 Service Unavailable\b|\b502 Bad Gateway\b|\bapi error: (?:429|5\d\d)\b|\b(?:rate_limit_error|overloaded_error|api_error)\b|\b(?:ECONNRESET|ETIMEDOUT|EAI_AGAIN)\b|\bretry-after\s*:/i,
    cls: "transient",
    scope: "any",
  },
  {
    // Issue and PR lookup failures only: gh says so about the issue or PR number. A bare "404", "could not
    // resolve" or "no body" elsewhere in a log is not an invalid input (it was a false escalation, #8696).
    pattern:
      /issue not found|could not resolve to an? (?:issue|pullrequest)\b|\bhttp 404\b[^\n]{0,200}\/(?:issues|pulls)\/\d+|\bissue\b[^\n]{0,200}(?:no body|does not exist)/i,
    cls: "invalid_input",
    scope: "error",
  },
];

/** The rule patterns, exported so tests can check them (boundedness guard, parity corpus). */
export const RULE_PATTERNS: readonly RegExp[] = RULES.map((rule) => rule.pattern);

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
