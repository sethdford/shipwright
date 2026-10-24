import { readFileSync } from "node:fs";
import { resolve } from "node:path";

export const ROOT = resolve(import.meta.dir, "../..");

/**
 * Per-machine state that loops, the daemon, pipelines and checks write under `.claude/` must never
 * be tracked: a tracked file is committed by the next loop iteration (#8665). The list is the set of
 * `.claude/` entries in .gitignore, so it cannot drift from what git ignores. A directory entry
 * (trailing `/`) matches everything below it; a file entry matches exactly that path.
 */
export function runtimeStatePatterns(gitignore: string): RegExp[] {
  const entries = gitignore
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith(".claude/"));
  return entries.map((entry) => {
    if (entry.includes("*") || entry.includes("!")) {
      throw new Error(`.gitignore .claude entry must be a literal path or directory: ${entry}`);
    }
    const escaped = entry.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return entry.endsWith("/") ? new RegExp(`^${escaped}`) : new RegExp(`^${escaped}$`);
  });
}

export const RUNTIME_STATE_PATTERNS: readonly RegExp[] = runtimeStatePatterns(
  readFileSync(resolve(ROOT, ".gitignore"), "utf8"),
);

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
