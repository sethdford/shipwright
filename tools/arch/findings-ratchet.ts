/** Pure logic of the findings ratchet (ADR-0008). The CLI is tools/arch/ast-scan.ts. */

/** rule id → file → number of findings. Every ratcheted rule is a key, even at zero. */
export type Counts = Record<string, Record<string, number>>;
export interface Finding {
  readonly ruleId: string;
  readonly file: string;
  readonly line: number;
  readonly message: string;
}
type Entry = [rule: string, file: string, count: number];

function sorted(c: Counts, keep: readonly string[] = []): Counts {
  const out: Counts = {};
  for (const rule of [...new Set([...Object.keys(c), ...keep])].sort()) {
    const files = c[rule] ?? {};
    const byFile: Record<string, number> = {};
    for (const file of Object.keys(files).sort()) byFile[file] = files[file] ?? 0;
    out[rule] = byFile;
  }
  return out;
}

const entries = (c: Counts): Entry[] =>
  Object.entries(c).flatMap(([rule, files]) =>
    Object.entries(files).map(([file, n]): Entry => [rule, file, n]),
  );

export function countFindings(findings: readonly Finding[], ratcheted: readonly string[]): Counts {
  const out: Counts = {};
  for (const f of findings) {
    const byFile = out[f.ruleId] ?? {};
    byFile[f.file] = (byFile[f.file] ?? 0) + 1;
    out[f.ruleId] = byFile;
  }
  return sorted(out, ratcheted);
}

/** Parses `ast-grep scan --json=stream` (one match per line; lines are 0-based there). */
export function parseScan(stdout: string): Finding[] {
  return stdout
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => {
      const m = JSON.parse(l) as {
        ruleId: string;
        file: string;
        range: { start: { line: number } };
        message: string;
      };
      return { ruleId: m.ruleId, file: m.file, line: m.range.start.line + 1, message: m.message };
    });
}

/** Entries that are new or above their baseline, with the baseline value (if any). */
export function grown(current: Counts, baseline: Counts): [...Entry, number | undefined][] {
  return entries(sorted(current))
    .map(([rule, file, n]): [...Entry, number | undefined] => [
      rule,
      file,
      n,
      baseline[rule]?.[file],
    ])
    .filter(([, , n, base]) => base === undefined || n > base);
}

/**
 * The baseline is a ratchet: counts may only go down, every entry must match reality, every
 * ratcheted rule (the keys of `current`) has a key, and no other rule does.
 */
export function checkFindings(current: Counts, baseline: Counts): string[] {
  const growth = grown(current, baseline).map(([rule, file, n, base]) =>
    base === undefined
      ? `${rule} ${file}: ${n} new finding(s). Fix them: baselined findings may only go down.`
      : `${rule} ${file}: ${n} findings (baseline ${base}). Fix the new one: baselined findings may only go down.`,
  );
  const loose = entries(sorted(current))
    .filter(([rule, file, n]) => n < (baseline[rule]?.[file] ?? 0))
    .map(([rule, file, n]) => `tighten baseline ${rule} ${file} to ${n}`);
  const stale = entries(sorted(baseline))
    .filter(([rule, file]) => rule in current && !current[rule]?.[file])
    .map(([rule, file]) => `remove baseline entry ${rule} ${file} (no findings left)`);
  const unseeded = Object.keys(current)
    .filter((rule) => !(rule in baseline))
    .map(
      (rule) =>
        `${rule} has no baseline entry. Seed it: bun tools/arch/ast-scan.ts --write-baseline`,
    );
  const foreign = Object.keys(baseline)
    .filter((rule) => !(rule in current))
    .map((rule) => `remove baseline entry ${rule} (not a ratcheted rule)`);
  return [...growth, ...loose, ...stale, ...unseeded, ...foreign];
}

/**
 * Seeds a rule the baseline does not know yet; for known rules it may only tighten or prune. The
 * result has a key for every ratcheted rule (empty when it reached zero, which the meta-test turns
 * into "promote it to severity: error") and none for other rules.
 */
export function nextFindingsBaseline(
  current: Counts,
  existing: Counts | undefined,
  ratcheted: readonly string[],
): { baseline: Counts } | { errors: string[] } {
  const errors: string[] = [];
  for (const [rule, file, n] of entries(sorted(current))) {
    const known = existing?.[rule];
    const base = known?.[file];
    if (known && base === undefined) {
      errors.push(`refusing to baseline new finding ${rule} ${file} (${n})`);
    } else if (base !== undefined && n > base) {
      errors.push(`refusing to raise baseline ${rule} ${file} from ${base} to ${n}`);
    }
  }
  if (errors.length > 0) return { errors };
  const kept: Counts = {};
  for (const rule of ratcheted) kept[rule] = current[rule] ?? {};
  return { baseline: sorted(kept) };
}

/** A Markdown table of per-rule totals, for $GITHUB_STEP_SUMMARY. */
export function summaryMarkdown(current: Counts): string {
  const rows = Object.entries(sorted(current)).map(([rule, files]) => {
    const total = Object.values(files).reduce((a, b) => a + b, 0);
    return `| ${rule} | ${Object.keys(files).length} | ${total} |`;
  });
  return ["| Ratcheted rule | Files | Findings |", "|---|---|---|", ...rows, ""].join("\n");
}
