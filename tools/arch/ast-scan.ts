/**
 * Runs every ast-grep rule over the files git knows (not a directory walk, so .gitignore/.ignore
 * cannot hide a tracked file). Rules with severity error must have no findings; ratcheted rules
 * (severity off + metadata.ratchet) are compared with tools/arch/findings-baseline.json (ADR-0008).
 *
 *   bun tools/arch/ast-scan.ts                    check (part of `bun run arch`)
 *   bun tools/arch/ast-scan.ts --write-baseline   tighten/prune the baseline, or seed a new rule
 *   bun tools/arch/ast-scan.ts --against <ref>    also fail if the baseline rose vs the merge base (CI)
 */
import { appendFileSync } from "node:fs";
import { join } from "node:path";
import { baselineAt, risesAgainst } from "./baseline-history";
import {
  type Counts,
  checkFindings,
  countFindings,
  type Finding,
  grown,
  nextFindingsBaseline,
  parseScan,
  summaryMarkdown,
} from "./findings-ratchet";
import { isRatcheted, loadRules, ROOT, trackedFiles } from "./rule-catalog";

const BASELINE_REL = "tools/arch/findings-baseline.json";
const SCANNED = /\.(ts|tsx|mts|cts|sh|bash)$|(^|\/)sw$/;
const NO_IGNORE = ["hidden", "dot", "exclude", "global", "parent", "vcs"].flatMap((k) => [
  "--no-ignore",
  k,
]);

async function scan(ratcheted: readonly string[]): Promise<Finding[]> {
  const files = (await trackedFiles()).filter((f) => SCANNED.test(f));
  const proc = Bun.spawn(
    [
      join(ROOT, "node_modules/.bin/ast-grep"),
      "scan",
      ...ratcheted.map((id) => `--error=${id}`),
      "--json=stream",
      "--color=never",
      ...NO_IGNORE,
      ...files,
    ],
    { cwd: ROOT, stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  // Any ast-grep error (a bad rule, an unreadable path) fails the scan, even if it found matches.
  // The only expected ones are the summary it prints when error-severity matches exist.
  const expected =
    /^(Error: \d+ error\(s\) found in code\.|Help: Scan succeeded and found error level diagnostics.*)$/;
  const errors = stderr.split("\n").filter((l) => /\berror\b/i.test(l) && !expected.test(l));
  if (errors.length > 0) throw new Error(`ast-grep scan reported errors:\n${stderr}`);
  return parseScan(stdout);
}

function print(findings: readonly Finding[], messages: Map<string, string>): void {
  for (const rule of new Set(findings.map((f) => f.ruleId))) {
    console.error(`\n${rule}: ${messages.get(rule)}`);
    for (const f of findings.filter((x) => x.ruleId === rule))
      console.error(`  ${f.file}:${f.line}`);
  }
}

function check(
  findings: readonly Finding[],
  current: Counts,
  baseline: Counts,
  messages: Map<string, string>,
): number {
  const strict = findings.filter((f) => !(f.ruleId in current));
  print(strict, messages);
  const problems = checkFindings(current, baseline);
  for (const p of problems) console.error(`RATCHET ${p}`);
  const growth = new Set(grown(current, baseline).map(([rule, file]) => `${rule}\0${file}`));
  print(
    findings.filter((f) => growth.has(`${f.ruleId}\0${f.file}`)),
    messages,
  );
  if (problems.length > 0) {
    console.error(
      `\nBaseline: ${BASELINE_REL}. After fixing, run: bun tools/arch/ast-scan.ts --write-baseline`,
    );
  }
  return strict.length + problems.length > 0 ? 1 : 0;
}

if (import.meta.main) {
  const rules = await loadRules();
  const ratcheted = rules.filter(isRatcheted).map((r) => r.id);
  const messages = new Map(rules.map((r) => [r.id, r.message ?? ""]));
  const findings = await scan(ratcheted);
  const current = countFindings(
    findings.filter((f) => ratcheted.includes(f.ruleId)),
    ratcheted,
  );
  const file = Bun.file(join(ROOT, BASELINE_REL));
  const existing = (await file.exists()) ? ((await file.json()) as Counts) : undefined;
  const at = Bun.argv.indexOf("--against");
  if (at > 0) {
    const ref = Bun.argv[at + 1] ?? "origin/main";
    // A base without the file (the PR that introduces it) is "no base": nothing can have risen.
    const promoted = new Set(rules.filter((r) => r.severity === "error").map((r) => r.id));
    const rises = risesAgainst(baselineAt(ref, BASELINE_REL, ROOT) ?? {}, existing ?? {}, promoted);
    for (const r of rises)
      console.error(`RATCHET ${r}. Baselines may not grow; fix the code instead.`);
    if (rises.length > 0) process.exit(1);
  }
  if (Bun.argv.includes("--write-baseline")) {
    const next = nextFindingsBaseline(current, existing, ratcheted);
    if ("errors" in next) {
      for (const e of next.errors) console.error(`RATCHET ${e}`);
      process.exit(1);
    }
    await Bun.write(file, `${JSON.stringify(next.baseline, null, 2)}\n`);
  } else {
    const summary = process.env.GITHUB_STEP_SUMMARY;
    if (summary && at < 0) {
      appendFileSync(summary, `### Ratcheted fitness findings\n\n${summaryMarkdown(current)}\n`);
    }
    process.exit(check(findings, current, existing ?? {}, messages));
  }
}
