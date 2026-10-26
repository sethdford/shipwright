// The #8709 round-7 fuzz corpus (#8715): every lead-in × prefix × phrase combination the escalation rules must agree
// on in TS and bash. Deterministic: a combination is kept when the lead-in or the prefix is empty, or when a fixed
// multiplicative hash of its index is divisible by 7, which gives 1786 rows. classify-fuzz.test.ts checks a sample
// on every run. `bun src/testing/fixtures/wave2/classify-fuzz.ts [--locale C|en_US.UTF-8|all]` checks all of them:
// CI runs one locale on pull requests and both on pushes to main (ts-check.yml), since each locale costs ~90 s.
import { classifyAndDecide } from "../../../contexts/learning";
import { BASH_LOCALES, type BashLocale, bashClassifyAll } from "../../bash-classify";
import { createTestEnv } from "../../test-env";

const E = "\x1b";
const LEADS: readonly string[] = [
  "",
  "✗ ",
  "✗  ",
  `${E}[38;2;248;113;113m${E}[1m✗${E}[0m `,
  "⚠\uFE0F ",
  "✗✗✗✗ ",
  "[ERROR] ",
  "[2026-10-26T12:00:00Z] ",
  "2026-10-26T12:00:00Z ",
  "2026/10/26 12:00:00 ",
  "\t",
  " ",
  "\u00a0",
  "✗\u00a0",
  "- ",
  "> ",
  "##[error]",
  "::error::",
  "× ",
  "× ×  ",
  "\uFEFF✗ ",
  "✗\r",
];
const PREFIXES: readonly string[] = [
  "",
  "PR creation failed: ",
  "pr creation failed:  ",
  "Plan stage produced API/CLI error instead of a plan: ",
  "Design stage produced API/CLI error instead of a design: ",
  "Plan stage produced API/CLI error instead of a design: ",
  "PLAN STAGE PRODUCED API/CLI ERROR INSTEAD OF AN PLAN: ",
  "Fatal CLI error: ",
  "CLI exited 1 with minimal output: ",
  "CLI exited 1234 with minimal output: ",
  "CLI exited  1 with minimal output: ",
  "Claude Code returned an error result: ",
  "pull request create failed: ",
  "PR creation failed: pull request create failed: ",
  "PR creation failed: PR creation failed: gh: ",
  "error: error: error: ",
  "gh: ",
  "Fatal CLI error:",
  "Fatal CLI error: Error: ",
];
const PHRASES: readonly string[] = [
  "HTTP 401: Bad credentials (https://api.github.com/graphql)",
  "Invalid API key · Please run /login",
  "Not logged in · Please run /login",
  "GraphQL: Could not resolve to an issue or pull request with the number of 9. (repository.issue)",
  "issue #12 does not exist.",
  'API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"x"}}',
  'Failed to authenticate. API Error: 403 {"type":"error","error":{"type":"permission_error"',
  "OAuth token has expired.",
  "authentication failed",
  "Bad credentials",
  "Bad credentials ",
  "Invalid API key·Please",
  "invalid api key provided.",
  "Authentication failed for 'https://github.com/o/r.git/'",
  "Request failed with status code 401",
  "401 Unauthorized - x",
  "Resource not accessible by integration",
  "issue not found",
  "CONTAMINATION: branch-switched",
];

/** The 1786 fuzz texts, in a fixed order. */
export function fuzzCorpus(): string[] {
  const out: string[] = [];
  let i = 0;
  for (const lead of LEADS)
    for (const prefix of PREFIXES)
      for (const phrase of PHRASES) {
        i++;
        if ((i * 2654435761) % 7 !== 0 && !(lead === "" || prefix === "")) continue;
        out.push(lead + prefix + phrase);
      }
  return out;
}

const ESCALATIONS: Readonly<Record<string, string>> = {
  auth_error: "auth",
  invalid_issue: "invalid_input",
  contamination: "contamination",
};
const tsEscalation = (text: string) => {
  const cls = classifyAndDecide({ text, attempts: [] }).class;
  return cls === "auth" || cls === "invalid_input" || cls === "contamination" ? cls : "-";
};

/** Rows whose escalation differs between TS and bash, or between bash in the given locales. */
export function fuzzDivergences(
  texts: readonly string[],
  locales: readonly BashLocale[] = BASH_LOCALES,
): string[] {
  const env = createTestEnv();
  try {
    const labels = locales.map((locale) => bashClassifyAll(env, texts, locale));
    return texts.flatMap((text, i) => {
      const ts = tsEscalation(text);
      const bash = labels.map((l) => ESCALATIONS[l[i] ?? ""] ?? "-");
      return bash.every((b) => b === ts)
        ? []
        : [`${JSON.stringify(text)}: ts=${ts} bash=${bash.join("/")}`];
    });
  } finally {
    env.cleanup();
  }
}

if (import.meta.main) {
  const arg = process.argv[process.argv.indexOf("--locale") + 1] ?? "all";
  const locales = BASH_LOCALES.filter((l) => arg === "all" || l === arg);
  if (locales.length === 0) {
    console.error(`--locale must be one of ${BASH_LOCALES.join(", ")} or all`);
    process.exit(2);
  }
  const texts = fuzzCorpus();
  const bad = fuzzDivergences(texts, locales);
  for (const line of bad) console.log(line);
  console.log(`rows=${texts.length} locales=${locales.join(",")} divergences=${bad.length}`);
  process.exit(bad.length === 0 ? 0 : 1);
}
