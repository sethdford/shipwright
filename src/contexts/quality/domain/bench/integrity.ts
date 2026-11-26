import { patchPaths } from "./holdout";
import type { BenchTask } from "./task";

/**
 * Integrity flags for one benchmark run (the SWE-bench Pro lesson: agents dig the gold fix out of
 * git history). Workspaces hold no future history, so the only ways left to the gold fix are the
 * harness's own cache and the network: either one voids the run. Probing history or touching the
 * test harness is kept as a warning for a human to read.
 */
export type IntegrityKind =
  | "cache-access"
  | "upstream-fetch"
  | "network-probe"
  | "history-probe"
  | "oracle-edit"
  | "test-edit"
  | "harness-edit";

export interface IntegrityFlag {
  readonly kind: IntegrityKind;
  /** void: the run cannot count as resolved. warn: shown in the report, the result stands. */
  readonly severity: "void" | "warn";
  readonly evidence: string;
}

export interface AuditContext {
  /** Harness directories an agent has no reason to touch (the full-history mirror, the cache). */
  readonly guardedPaths: readonly string[];
}

const GIT_NET = /\bgit\b[^\n|;&]*\s(fetch|pull|clone|ls-remote|remote\s+(add|set-url))\b/;
const URLISH = /(https?:\/\/|git@|ssh:\/\/|git:\/\/)\S+/;
const TOOL_NET = /(^|[\s;&|(])(gh|curl|wget|hub)\s/;
const GH = /(^|[\s;&|(])(gh|hub)\s/;
const FORGE = /github\.com|githubusercontent\.com|gitlab\.|bitbucket\./;
const HISTORY =
  /\bgit\b[^\n|;&]*\s(log|rev-list|shortlog|show-branch)\b[^\n|;&]*\s--(all|reflog|branches|remotes|tags)\b|\bgit\b[^\n|;&]*\s(reflog|for-each-ref|show-ref|fsck)\b|--batch-all-objects|--unreachable|--lost-found/;

const clip = (s: string) => (s.length > 160 ? `${s.slice(0, 157)}...` : s);

/** `owner/name` of an https repo URL, lower-cased; null for a local path. */
export function repoSlug(repo: string): string | null {
  const m = /^https:\/\/[^/]+\/([^/]+\/[^/]+?)(\.git)?\/?$/.exec(repo);
  return m?.[1] ? m[1].toLowerCase() : null;
}

function auditCommand(cmd: string, task: BenchTask, ctx: AuditContext): IntegrityFlag | null {
  const lower = cmd.toLowerCase();
  const slug = repoSlug(task.repo);
  const guarded = ctx.guardedPaths.find((p) => p.length > 1 && cmd.includes(p));
  if (guarded) return { kind: "cache-access", severity: "void", evidence: clip(cmd) };
  const namesRepo = slug !== null && lower.includes(slug);
  if (GIT_NET.test(cmd) && (namesRepo || cmd.includes(task.repo)))
    return { kind: "upstream-fetch", severity: "void", evidence: clip(cmd) };
  if (TOOL_NET.test(cmd) && namesRepo)
    return { kind: "upstream-fetch", severity: "void", evidence: clip(cmd) };
  const forge = GH.test(cmd) || (TOOL_NET.test(cmd) && FORGE.test(lower));
  if ((GIT_NET.test(cmd) && URLISH.test(cmd)) || forge)
    return { kind: "network-probe", severity: "warn", evidence: clip(cmd) };
  if (HISTORY.test(cmd)) return { kind: "history-probe", severity: "warn", evidence: clip(cmd) };
  return null;
}

/** Flags from the commands (and file paths) an agent used during its run, one per command. */
export function auditCommands(
  commands: readonly string[],
  task: BenchTask,
  ctx: AuditContext,
): readonly IntegrityFlag[] {
  const flags: IntegrityFlag[] = [];
  for (const cmd of commands) {
    const f = auditCommand(cmd, task, ctx);
    if (f) flags.push(f);
  }
  return flags;
}

const TEST_FILE =
  /(^|\/)(tests?|__tests__|spec|specs)\/|[._-](test|spec)s?\.[A-Za-z0-9]+$|_test\.go$|(^|\/)test_[^/]+\.py$/;
const HARNESS =
  /(^|\/)(bunfig\.toml|jest\.config\.[a-z]+|vitest\.config\.[a-z]+|pytest\.ini|conftest\.py|tox\.ini|karma\.conf\.[a-z]+|\.mocharc\.[a-z]+)$|^\.github\/workflows\/|^scripts\/sw-test-all\.sh$|^scripts\/lib\/test-gate[^/]*$/;

/** Files the patch changes or deletes that existed before (new files are not test tampering). */
function touchedExisting(patch: string): readonly string[] {
  const out: string[] = [];
  for (const part of patch.split(/^(?=diff --git )/m)) {
    if (/^new file mode/m.test(part)) continue;
    out.push(...patchPaths(part));
  }
  return [...new Set(out)];
}

/** Paths a task's test commands run directly, e.g. `bash scripts/x-test.sh`. */
function commandFiles(task: BenchTask): ReadonlySet<string> {
  const files = new Set<string>();
  for (const argv of task.testCommands)
    for (const a of argv.slice(1)) if (/^[\w./-]+\.[A-Za-z0-9]+$/.test(a)) files.add(a);
  return files;
}

/** Flags from the agent's patch: edits to the hidden oracle, to existing tests, to test config. */
export function auditPatch(patch: string, task: BenchTask): readonly IntegrityFlag[] {
  const oracle = new Set([...patchPaths(task.testPatch ?? ""), ...commandFiles(task)]);
  const flags: IntegrityFlag[] = [];
  for (const path of patchPaths(patch)) {
    if (oracle.has(path)) flags.push({ kind: "oracle-edit", severity: "warn", evidence: path });
    else if (HARNESS.test(path))
      flags.push({ kind: "harness-edit", severity: "warn", evidence: path });
  }
  for (const path of touchedExisting(patch)) {
    if (!oracle.has(path) && TEST_FILE.test(path))
      flags.push({ kind: "test-edit", severity: "warn", evidence: path });
  }
  return flags;
}

/** One line per flag for the results log, e.g. `void:cache-access: git -C ... log --all`. */
export const flagLine = (f: IntegrityFlag) => `${f.severity}:${f.kind}: ${f.evidence}`;

export const isVoid = (flags: readonly IntegrityFlag[]) => flags.some((f) => f.severity === "void");

/** At most `max` flags, voiding ones first, so one noisy run cannot bloat the log. */
export function topFlags(flags: readonly IntegrityFlag[], max = 20): readonly IntegrityFlag[] {
  const seen = new Set<string>();
  const unique = flags.filter((f) => {
    const key = flagLine(f);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  return [
    ...unique.filter((f) => f.severity === "void"),
    ...unique.filter((f) => f.severity !== "void"),
  ].slice(0, max);
}
