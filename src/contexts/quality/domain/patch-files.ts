import type { FileChange } from "./change-features";

/**
 * Per-file line counts from a unified diff, for a candidate held only as a patch (a tournament
 * attempt's snapshot). Pure. Matches `git diff --numstat` for text files; binary files count 0.
 */
export function filesFromPatch(patch: string): FileChange[] {
  const out: { path: string; additions: number; deletions: number }[] = [];
  let cur: { path: string; additions: number; deletions: number } | null = null;
  let inHunk = false;
  for (const line of patch.split("\n")) {
    const head = /^diff --git a\/(.+?) b\/(.+)$/.exec(line);
    if (head) {
      cur = { path: head[2] as string, additions: 0, deletions: 0 };
      out.push(cur);
      inHunk = false;
    } else if (!cur) {
    } else if (line.startsWith("@@")) {
      inHunk = true;
    } else if (inHunk && line.startsWith("+")) {
      cur.additions++;
    } else if (inHunk && line.startsWith("-")) {
      cur.deletions++;
    }
  }
  return out;
}
