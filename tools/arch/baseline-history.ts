/**
 * Anti-laundering for baselines (ADR-0008): compared with the merge base of a branch, no baseline
 * may gain an entry or a higher count, and no rule may lose its key. Used by `ast-scan.ts --against`
 * and `size-ratchet.ts --against`.
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
export function risesAgainst(
  base: Grouped,
  head: Grouped,
  promoted: ReadonlySet<string> = new Set(),
): string[] {
  const out: string[] = [];
  // A group the base has and HEAD lacks: the rule was renamed or removed, so its debt left the
  // baseline without being paid. Rules keep their key even at zero (an empty object). The one
  // exception is a promotion: a rule that is severity: error at HEAD must drop its key (checkFindings
  // requires it), so `promoted` (the error-severity rule ids at HEAD) may be missing.
  for (const group of Object.keys(base)) {
    if (!(group in head) && !promoted.has(group)) {
      out.push(
        `${group} is missing from the baseline: a rule was renamed or removed. Keep its key (an empty object when it reached zero)`,
      );
    }
  }
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
