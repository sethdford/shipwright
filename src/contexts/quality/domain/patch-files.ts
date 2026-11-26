import type { FileChange } from "./change-features";
import { headerPath } from "./diff-paths";

type Entry = { path: string; additions: number; deletions: number };

/** `diff --git a/x b/x` with unquoted paths; quoted or ambiguous ones wait for the ---/+++ lines. */
const SIMPLE_HEAD = /^diff --git a\/(\S+) b\/(\S+)$/;

/**
 * Per-file line counts from a unified diff, for a candidate held only as a patch (a tournament
 * attempt's snapshot). Pure. Matches `git diff --numstat` for text files; binary files count 0.
 * Headers are read only before a file's first hunk, so content lines are never mistaken for them.
 */
export function filesFromPatch(patch: string): FileChange[] {
  const out: Entry[] = [];
  let cur: Entry | null = null;
  let inHunk = false;
  for (const line of patch.split("\n")) {
    if (line.startsWith("diff --git ")) {
      cur = { path: SIMPLE_HEAD.exec(line)?.[2] ?? "", additions: 0, deletions: 0 };
      out.push(cur);
      inHunk = false;
    } else if (!cur) {
    } else if (!inHunk && (line.startsWith("+++ ") || line.startsWith("--- "))) {
      const path = headerPath(line.slice(4));
      if (path !== null && (line.startsWith("+++ ") || cur.path === "")) cur.path = path;
    } else if (line.startsWith("@@")) {
      inHunk = true;
    } else if (inHunk && line.startsWith("+")) {
      cur.additions++;
    } else if (inHunk && line.startsWith("-")) {
      cur.deletions++;
    }
  }
  return out.filter((e) => e.path !== "");
}
