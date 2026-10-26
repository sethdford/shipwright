import { resolve } from "node:path";

export const ROOT = resolve(import.meta.dir, "../..");

/**
 * Per-machine state under `.claude/` must never be tracked: a tracked file is committed by the next
 * loop iteration (#8665). The check asks git itself, so anchored, nested, `?`/`[]` and info/exclude
 * rules all count the way git counts them. `--no-index` reports tracked files too, so a force-added
 * file that an ignore rule covers is a violation. The developer's global excludes file is switched off:
 * a global `.claude/` or `*.md` must not make the check flag real config (#8667).
 */
export function ignoredByGit(
  paths: readonly string[],
  root = ROOT,
  env: Record<string, string> = {},
): string[] {
  if (paths.length === 0) return [];
  const proc = Bun.spawnSync(
    ["git", "-c", "core.excludesFile=/dev/null", "check-ignore", "--no-index", "--stdin", "-z"],
    {
      cwd: root,
      env: { ...process.env, ...env },
      stdin: new TextEncoder().encode(paths.map((p) => `${p}\0`).join("")),
    },
  );
  // Exit 0: some paths are ignored; 1: none are; anything else is a failure to ask git.
  if (proc.exitCode !== 0 && proc.exitCode !== 1) {
    throw new Error(`git check-ignore failed: ${proc.stderr.toString()}`);
  }
  return proc.stdout.toString().split("\0").filter(Boolean);
}

/** Files git tracks in the index (`--cached` only). */
export function trackedInIndex(root = ROOT): string[] {
  const proc = Bun.spawnSync(["git", "ls-files", "-z", "--cached"], { cwd: root });
  if (proc.exitCode !== 0) throw new Error(`git ls-files failed: ${proc.stderr.toString()}`);
  return proc.stdout.toString().split("\0").filter(Boolean);
}

/** Tracked `.claude/` files that git ignores: runtime state that was committed, or force-added. */
export function trackedRuntimeState(root = ROOT): string[] {
  return ignoredByGit(
    trackedInIndex(root).filter((f) => f.startsWith(".claude/")),
    root,
  );
}

if (import.meta.main) {
  const found = trackedRuntimeState();
  for (const f of found) {
    console.error(
      `RS ${f} — runtime state must not be tracked. Run: git rm --cached "${f}" and keep it in .gitignore.`,
    );
  }
  process.exit(found.length ? 1 : 0);
}
