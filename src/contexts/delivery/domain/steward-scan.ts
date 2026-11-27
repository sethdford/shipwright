/**
 * The pre-PR self-scan (ADR-0017): deterministic checks over the lines a change adds, run on the
 * final diff right before the branch is pushed. A secret blocks outright (it must never reach
 * the remote); conflict markers and focused tests get one fix round; the rest are notes for the
 * PR body. Pure: the unified diff comes in as text.
 */

export type ScanSeverity = "block" | "fix" | "note";

export interface ScanFinding {
  readonly rule: string;
  readonly severity: ScanSeverity;
  readonly path: string;
  /** Line number in the new file. */
  readonly line: number;
  readonly message: string;
}

interface ScanRule {
  readonly id: string;
  readonly severity: ScanSeverity;
  readonly pattern: RegExp;
  readonly message: string;
  /** Only files whose path matches (default: every file). */
  readonly paths?: RegExp;
}

const TEST_FILE =
  /(^|\/)(tests?|__tests__|spec|e2e)\/|\.(test|spec|e2e)\.[cm]?[jt]sx?$|_test\.(go|py|sh)$|-test\.sh$/;
const SOURCE_FILE = /\.[cm]?[jt]sx?$/;

const RULES: readonly ScanRule[] = [
  {
    id: "secret-private-key",
    severity: "block",
    pattern: /-----BEGIN (RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY( BLOCK)?-----/,
    message: "a private key",
  },
  {
    id: "secret-aws",
    severity: "block",
    pattern: /\b(AKIA|ASIA)[0-9A-Z]{16}\b/,
    message: "an AWS access key id",
  },
  {
    id: "secret-github",
    severity: "block",
    pattern: /\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b/,
    message: "a GitHub token",
  },
  {
    id: "secret-anthropic",
    severity: "block",
    pattern: /\bsk-ant-[A-Za-z0-9_-]{20,}/,
    message: "an Anthropic API key",
  },
  {
    id: "secret-openai",
    severity: "block",
    // Project/service keys carry a prefix; legacy keys are 48 letters and digits, no dashes. A
    // plain kebab-case word such as sk-learn-compatible-... is not a key.
    pattern: /\bsk-(?:(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}|[A-Za-z0-9]{40,})(?![A-Za-z0-9_-])/,
    message: "an OpenAI API key",
  },
  {
    id: "secret-slack",
    severity: "block",
    pattern: /\bxox[abposr]-[A-Za-z0-9-]{10,}/,
    message: "a Slack token",
  },
  {
    id: "secret-stripe",
    severity: "block",
    pattern: /\b[sr]k_live_[A-Za-z0-9]{20,}/,
    message: "a live Stripe key",
  },
  {
    id: "secret-google",
    severity: "block",
    pattern: /\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])/,
    message: "a Google API key",
  },
  {
    id: "conflict-marker",
    severity: "fix",
    // A bare ======= is also a setext heading underline, so only the two ends count.
    pattern: /^(<{7}|>{7})( |$)/,
    message: "a merge conflict marker",
  },
  {
    id: "focused-test",
    severity: "fix",
    pattern:
      /\b(describe|it|test|context|suite)\.only\b|\[\s*["'`]only["'`]\s*\]|\b(fdescribe|fit)\s*\(/,
    message: "a focused test (.only) that silently skips the rest of the suite",
    paths: TEST_FILE,
  },
  {
    id: "debugger",
    severity: "fix",
    pattern: /^\s*debugger;?\s*$|\bbreakpoint\(\)|\bpdb\.set_trace\(\)/,
    message: "a debugger statement",
  },
  {
    id: "skipped-test",
    severity: "note",
    pattern: /\b(describe|it|test)\.skip\s*\(|\b(xdescribe|xit)\s*\(/,
    message: "a skipped test",
    paths: TEST_FILE,
  },
  {
    id: "console-log",
    severity: "note",
    pattern: /\bconsole\.log\(/,
    message: "a console.log in source",
    paths: SOURCE_FILE,
  },
];

export interface AddedLine {
  readonly path: string;
  readonly line: number;
  readonly text: string;
}

/**
 * The added lines of a unified diff with their new-file line numbers. Binary hunks are skipped.
 * Hunk bodies are consumed by the counts in their `@@` header, so an added line that reads
 * `++ x` (`+++ x` in the diff) is content, never a new file header.
 */
export function addedLines(diff: string): AddedLine[] {
  const out: AddedLine[] = [];
  let path = "";
  let next = 0;
  let oldLeft = 0;
  let newLeft = 0;
  for (const raw of diff.split("\n")) {
    if (oldLeft > 0 || newLeft > 0) {
      if (raw.startsWith("+")) {
        if (path) out.push({ path, line: next, text: raw.slice(1) });
        next++;
        newLeft--;
      } else if (raw.startsWith("-")) oldLeft--;
      else if (raw.startsWith(" ") || raw === "") {
        next++;
        oldLeft--;
        newLeft--;
      }
      continue;
    }
    if (raw.startsWith("+++ ")) {
      path = raw === "+++ /dev/null" ? "" : raw.slice(4).replace(/^b\//, "");
      continue;
    }
    const hunk = /^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(raw);
    if (!hunk) continue;
    oldLeft = Number(hunk[1] ?? 1);
    next = Number(hunk[2]);
    newLeft = Number(hunk[3] ?? 1);
  }
  return out;
}

/**
 * Applies every rule to every added line. There is no in-line opt-out: the lines come from the
 * agent the scan is checking, so anything it could write to silence a rule would silence it.
 */
export function scanDiff(diff: string): ScanFinding[] {
  const findings: ScanFinding[] = [];
  for (const added of addedLines(diff)) {
    for (const rule of RULES) {
      if (rule.paths && !rule.paths.test(added.path)) continue;
      if (!rule.pattern.test(added.text)) continue;
      findings.push({
        rule: rule.id,
        severity: rule.severity,
        path: added.path,
        line: added.line,
        message: rule.message,
      });
    }
  }
  return findings;
}

export type ScanVerdict = "block" | "fix" | "pass";

export function scanVerdict(findings: readonly ScanFinding[]): ScanVerdict {
  if (findings.some((f) => f.severity === "block")) return "block";
  return findings.some((f) => f.severity === "fix") ? "fix" : "pass";
}

/** True when `text` holds a secret by the block rules (used for the fixer's reply notes too). */
export function containsSecret(text: string): boolean {
  return RULES.some((r) => r.severity === "block" && r.pattern.test(text));
}
