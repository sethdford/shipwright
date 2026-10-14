/**
 * Anti-laundering for baselines (ADR-0008): compared with the merge base of a branch, no baseline
 * may gain an entry or a higher count. Used by `ast-scan.ts --against` and `size-ratchet.ts --against`.
 */
type Grouped = Record<string, Record<string, number>>;

function git(root: string, ...args: string[]): { ok: boolean; out: string; err: string } {
  const p = Bun.spawnSync(["git", ...args], { cwd: root });
  return { ok: p.exitCode === 0, out: p.stdout.toString(), err: p.stderr.toString() };
}

/** The baseline at the merge base of HEAD and `ref`; undefined when the file did not exist there. */
export function baselineAt(ref: string, path: string, root: string): Grouped | undefined {
  const base = git(root, "merge-base", "HEAD", ref);
  if (!base.ok) throw new Error(`git merge-base HEAD ${ref} failed: ${base.err.trim()}`);
  const shown = git(root, "show", `${base.out.trim()}:${path}`);
  return shown.ok ? (JSON.parse(shown.out) as Grouped) : undefined;
}

/** Entries that are new or higher than at the base, within groups the base already has. */
export function risesAgainst(base: Grouped, head: Grouped): string[] {
  const out: string[] = [];
  for (const [group, entries] of Object.entries(head)) {
    const known = base[group];
    if (!known) continue;
    for (const [key, n] of Object.entries(entries)) {
      const was = known[key];
      if (was === undefined) out.push(`${group} ${key} is new against the base branch`);
      else if (n > was)
        out.push(`${group} ${key} rose from ${was} to ${n} against the base branch`);
    }
  }
  return out;
}
