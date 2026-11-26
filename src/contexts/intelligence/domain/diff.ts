/** One file a unified diff touches: its path after the change and the new-side lines it adds or edits. */
export interface ChangedFile {
  readonly path: string;
  /** Path before the change; differs from `path` for a rename, "" for a new file. */
  readonly oldPath: string;
  readonly deleted: boolean;
  /** 1-based new-side lines that were added or changed (empty for a pure deletion of lines). */
  readonly lines: readonly number[];
  /** New-side hunk starts, so a hunk that only deletes still marks where it happened. */
  readonly hunks: readonly number[];
}

interface Draft {
  path: string;
  oldPath: string;
  deleted: boolean;
  lines: number[];
  hunks: number[];
}

const HUNK = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/;

function unquote(p: string): string {
  return p.replace(/^"|"$/g, "").replace(/^[ab]\//, "");
}

/** Parses `git diff` output (as `git diff base...HEAD` prints it) into the files and lines it changes. */
export function parseUnifiedDiff(patch: string): ChangedFile[] {
  const out: Draft[] = [];
  let cur: Draft | undefined;
  let line = 0;
  for (const raw of patch.split("\n")) {
    if (raw.startsWith("diff --git ")) {
      cur = { path: "", oldPath: "", deleted: false, lines: [], hunks: [] };
      out.push(cur);
    } else if (!cur) {
    } else if (raw.startsWith("--- ")) {
      cur.oldPath = raw === "--- /dev/null" ? "" : unquote(raw.slice(4));
    } else if (raw.startsWith("+++ ")) {
      cur.deleted = raw === "+++ /dev/null";
      cur.path = cur.deleted ? cur.oldPath : unquote(raw.slice(4));
    } else if (raw.startsWith("@@")) {
      line = Number(HUNK.exec(raw)?.[1] ?? 0);
      cur.hunks.push(line);
    } else if (raw.startsWith("+")) {
      cur.lines.push(line);
      line += 1;
    } else if (raw.startsWith(" ")) line += 1;
  }
  return out.filter((f) => f.path.length > 0);
}
