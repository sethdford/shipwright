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
  /gh auth login|error|fail|fatal|exception|::error::|enoent|eacces|not found|lockfile|invalid|unauthori[sz]ed|forbidden|denied|overloaded|rate[ _-]?limit|timed? ?out|(?:^|[^0-9])[45]\d\d(?:[^0-9]|$)|econn|etimedout|socket hang up|unavailable|authentication|not logged in|refus|contaminat|expired|revoked|could not resolve|does not exist|claude_code_oauth_token|bad credentials|gh_token|not accessible/i;

interface Rule {
  readonly pattern: RegExp;
  readonly cls: FailureClass;
  /** "error" rules search error-like lines only; "any" rules search the whole text. */
  readonly scope: "any" | "error";
}

// The escalation lead-in (#8696): what may come before an anchored auth or invalid-input phrase on its line.
// Real emitters (gh, git, the Claude CLI, Shipwright's own logs) print at column 0. Test runners (rspec, jest,
// mocha, Playwright, node:test, go test), stack traces and verbose agent prose indent, so the lead-in allows no
// leading whitespace. It is, in order: an optional ISO timestamp (`2026-10-25T12:00:00Z`, `+00:00`, `2026/10/25
// 12:00:00`), an optional `[timestamp] `, an optional `[ERROR] `, then up to three of Shipwright's glyphs ✗ ✘ × ⚠
// (⚠ optionally with U+FE0F).
// No punctuation: `- `, `+ `, `> `, `| `, `* ` and `# ` start diff, quote, table, list and heading lines.
// Explicit and locale-independent, the same as bash (daemon-failure.sh, _DAEMON_LEAD) under LC_ALL=C and UTF-8.
const LEAD = String.raw`^(?:\d{4}[\-/]\d\d[\-/]\d\d[T ][\d:.]{1,20}(?:Z|[+\-]\d\d:?\d\d)? {1,2})?(?:\[\d[\dTZ:. +\-]{0,38}\] {1,2})?(?:\[(?:error|err|fatal)\] {1,2})?(?:(?:✗|✘|×|⚠|\uFE0F) {0,2}){0,3}`;
// Up to two tool or annotation prefixes after the lead-in (`##[error]Error: ...`, `gh: error: ...`).
const PREFIX = String.raw`(?:(?:gh|error|fatal)[ :]{1,3}|##\[error\] ?|::error:: ?|claude code returned an error result: |fatal cli error: |cli exited \d{1,3} with minimal output: |pr creation failed: |pull request create failed: |(?:plan|design) stage produced api/cli error instead of an? (?:plan|design): ){0,2}`;
// What may end a prose-prone phrase: end of line or punctuation, never another word.
const END = String.raw`(?:[ \t]{0,3}$|[.:;!,])`;
// A host or repository name, and a URL, as explicit ASCII sets (no negated class: see LEAD).
const HOST = String.raw`[A-Za-z0-9.\-]{1,253}`;
const URL_CHARS = String.raw`[A-Za-z0-9:/._~%@+=?&#\-]`;
// The Anthropic API's authentication error body: JSON from the CLI and JS SDK, a Python repr from the Python SDK.
// A quote may be backslash-escaped: the body inside a stream-json "result" string.
const Q = String.raw`\\?["']`;
const AUTH_BODY = String.raw`\{${Q}type${Q}: ?${Q}error${Q}, ?${Q}error${Q}: ?\{${Q}type${Q}: ?${Q}(?:authentication_error|permission_error)${Q}`;
// Auth phrases, anchored after LEAD and PREFIX. Prose-prone phrases are end-anchored or need a structured tail.
const AUTH_PHRASES = [
  String.raw`(?:claude code )?authentication failed(?:${END}| for '| for https?://| — check )`,
  String.raw`failed to authenticate${END}`,
  String.raw`api error: 401(?:[ \t:.,{]|$)`,
  String.raw`invalid api key(?:${END}|[ \t]{0,3}·| provided${END})`,
  String.raw`invalid x-api-key(?:${END}| token${END})`,
  String.raw`oauth token (?:is |has |has been )?(?:expired|invalid|revoked)(?:${END}|[ \t]{0,3}·)`,
  String.raw`not logged in(?:${END}|[ \t]{0,3}·| to )`,
  "you are not logged into any github hosts",
  "to get started with github cli, please run: {1,2}gh auth login",
  String.raw`authentication required${END}`,
  String.raw`http 401: requires authentication|requires authentication \(http 401\)`,
  String.raw`(?:http 401: )?bad credentials(?:[ \t]{0,3}\((?:https?://|http 401\))|[ \t]{0,3}$)`,
  String.raw`(?:unhandled error: )?(?:requesterror \[httperror\]|httperror): (?:bad credentials|requires authentication)`,
  String.raw`request failed with status (?:code )?401(?:${END}| unauthorized${END})`,
  String.raw`401 unauthorized(?:${END}| - )`,
  String.raw`claude_code_oauth_token (?:is )?not set${END}`,
  "to use github cli in a github actions workflow, set the ",
  String.raw`could not read (?:username|password) for '${URL_CHARS}{1,200}': (?:terminal prompts disabled|no such device or address|device not configured)`,
  String.raw`unable to access '${URL_CHARS}{1,200}': the requested url returned error: 40[13]`,
  "remote: write access to repository not granted",
  String.raw`[A-Za-z0-9._\-]{1,64}@${HOST}: permission denied \(publickey`,
  String.raw`(?:remote: )?permission to [A-Za-z0-9._/\-]{1,200} denied to `,
  String.raw`npm (?:err!|error) (?:code e401|code eneedauth|401 unauthorized)`,
  String.raw`error response from daemon: [A-Za-z0-9 :/._"'?=&%@+\-]{0,255}unauthorized: authentication required`,
  String.raw`get https?://${URL_CHARS}{1,255} - 401[ \t]{0,3}$`,
  // anthropic-sdk-go: `POST "https://api.anthropic.com/v1/messages": 401 Unauthorized (Request-ID: ...) {...}`.
  String.raw`(?:panic: )?post "https?://${URL_CHARS}{1,255}": 40[13] (?:unauthorized|forbidden)`,
  String.raw`(?:http 403: |graphql: )?resource not accessible by (?:integration|personal access token)`,
  "the token in [a-z_]{1,40} is invalid",
  'please run [`"]?claude login',
  AUTH_BODY,
].join("|");
// Structured forms that may be indented: the bare API type name after an error prefix (ending at `:` or the end
// of the line, so "error: authentication_error is now mapped ..." does not escalate), and `gh auth status`'s
// indented `X` lines.
const AUTH_INDENTED = [
  String.raw`(?:error|fatal)[ :]{1,3}(?:401 )?authentication_error(?::|[ \t]{0,3}$)`,
  String.raw`x failed to log in to ${HOST} (?:account|using token)`,
  String.raw`x ${HOST}: authentication failed`,
  "- the token in [a-z_]{1,40} is invalid",
].join("|");
// The structured 401/403 response, after its emitter's token at the anchored lead-in: the CLI's `API Error: 401
// {...}` (also after Claude Code's column-0 `● `/`⏺ `), `Error: 401 {...}`, the JS SDK's `AuthenticationError: 401
// {...}`, the Python SDK's `anthropic.AuthenticationError: Error code: 401 - {...}`. Anchored, so a test code frame,
// an assertion diff, a diff hunk or indented prose that quotes the body does not escalate. A stream-json `"result"`
// field is not matched: the current CLI puts its own text there (`Invalid API key · ...`), which the phrases catch.
const SDK_ERROR = String.raw`(?:[a-z_]{1,30}\.){0,3}(?:authentication|permissiondenied)error: (?:error code: )?`;
const AUTH_RESPONSE = String.raw`${LEAD}(?:(?:●|⏺) )?${PREFIX}(?:${SDK_ERROR}|api error: |error code: )?40[13](?: -)? ${AUTH_BODY}`;
// gh lookup failures for an issue or PR number, anchored after LEAD and PREFIX.
const INVALID_PHRASES = [
  String.raw`graphql(?: error)?: could not resolve to an? (?:issue|pullrequest)(?:[ \t.,]|$)`,
  String.raw`http 404: not found \(https:\/\/api\.github\.com\/repos\/[A-Za-z0-9._\-]{1,100}\/[A-Za-z0-9._\-]{1,100}\/(?:issues|pulls)\/\d{1,10}\)`,
  String.raw`issue not found(?:[ \t]{0,5}$|:)`,
  String.raw`issue #?\d{1,10} does not exist${END}`,
].join("|");

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
    // scoped to error lines. The refusal is the line sw-e2e-integration-test.sh prints (`⚠ Skipping ...`); its
    // lead-in is whitespace and literal glyphs (⚠, U+FE0F, ✗ ✘ ×), the same in bash under any locale. The reason is a
    // fixed list.
    pattern:
      /^(?:[ \t]|⚠|\uFE0F|✗|✘|×){0,4}Skipping integration tests: refusing to run inside a build-loop test gate[ \t]{0,20}$|^CONTAMINATION: (?:pipeline-state-missing|branch-switched)(?:[ \t]|$)/im,
    cls: "contamination",
    scope: "error",
  },
  {
    // Structured lines only (#8696): an anchored phrase after LEAD, an indented structured form, or the
    // structured 401 authentication_error response anywhere. A test name or prose sentence that mentions
    // 401 or "not logged in" does not escalate.
    pattern: new RegExp(
      `${LEAD}${PREFIX}(?:${AUTH_PHRASES})|^[ \t]{0,8}(?:${AUTH_INDENTED})|${AUTH_RESPONSE}`,
      "im",
    ),
    cls: "auth",
    scope: "error",
  },
  {
    // Anchored after the same LEAD and PREFIX as auth. Second, as in bash: before the environment rules (the
    // sandbox warning prints on every run on a host without bubblewrap) and before the log-text transient rule,
    // so "HTTP 503" next to a missing issue is invalid input, not transient (#8696).
    pattern: new RegExp(`${LEAD}${PREFIX}(?:${INVALID_PHRASES})`, "im"),
    cls: "invalid_input",
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
