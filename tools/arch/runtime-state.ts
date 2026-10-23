import { resolve } from "node:path";

export const ROOT = resolve(import.meta.dir, "../..");

/**
 * Per-machine state that loops, the daemon, pipelines and checks write under `.claude/`. It must never
 * be tracked: a tracked file is committed by the next loop iteration (#8665).
 */
export const RUNTIME_STATE_PATTERNS: readonly RegExp[] = [
  /^\.claude\/loop-logs\//,
  /^\.claude\/test-holdout\//,
  /^\.claude\/evidence\/[^/]+\.json$/,
  /^\.claude\/(pipeline-artifacts|worktrees)\//,
  /^\.claude\/(loop-state\.md|pipeline-state\.md|platform-hygiene\.json|intelligence-cache\.json)$/,
  /^\.claude\/(recovery-state\.json|daemon-config\.json|code-review\.json|hygiene-report\.json|pr-draft\.md)$/,
];

/** Paths in `files` that match the runtime-state list. */
export function runtimeStateViolations(files: readonly string[]): string[] {
  return files.filter((f) => RUNTIME_STATE_PATTERNS.some((p) => p.test(f)));
}

/** Files git tracks in the index (`--cached` only: an untracked file is not a violation). */
export function trackedInIndex(root = ROOT): string[] {
  const proc = Bun.spawnSync(["git", "ls-files", "-z", "--cached"], { cwd: root });
  if (proc.exitCode !== 0) throw new Error(`git ls-files failed: ${proc.stderr.toString()}`);
  return proc.stdout.toString().split("\0").filter(Boolean);
}

if (import.meta.main) {
  const found = runtimeStateViolations(trackedInIndex());
  for (const f of found) {
    console.error(
      `RS ${f} — runtime state must not be tracked. Run: git rm --cached "${f}" and keep it in .gitignore.`,
    );
  }
  process.exit(found.length ? 1 : 0);
}
