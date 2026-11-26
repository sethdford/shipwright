/**
 * Code survival: how much of a merged change is still in the codebase some days later. Pure.
 *
 * "Merged" is a weak label for a coding agent's work: a PR can merge and then be rewritten line by
 * line over the next week without ever being reverted. OpenHands found that a critic trained on
 * benchmark passes ranks real PRs worse than chance, while one trained on what survives in the
 * codebase ranks them well (AUC about 0.69). So the verifier's production label is: merged, not
 * reverted, and most of its added lines still present at the horizon.
 *
 * Survival is measured per file as a multiset match of the change's significant added lines
 * against the same file at the horizon commit. Trivial lines (blank, lone braces, short tokens)
 * are left out: they match by accident and would inflate survival. A renamed file counts as not
 * surviving, which errs toward the stricter label.
 */

export const SURVIVAL_RULE = {
  /** Days after the merge at which survival is measured. */
  horizonDays: 21,
  /** At least this share of significant added lines must remain for label 1. */
  minRate: 0.5,
  /** Changes with fewer significant added lines keep the plain merge label. */
  minLines: 3,
} as const;

/** The added lines of one change, per file, and the same files at the horizon (null: gone). */
export interface SurvivalInput {
  readonly added: ReadonlyMap<string, readonly string[]>;
  readonly later: ReadonlyMap<string, string | null>;
}

export interface SurvivalSample {
  /** Significant added lines. */
  readonly added: number;
  /** Of those, still present at the horizon. */
  readonly kept: number;
  /** kept / added; null when there were no significant lines. */
  readonly rate: number | null;
}

const TRIVIAL = /^[\s{}()[\];,]*$|^(else|end|fi|done|esac|then|do|return;?|break;?|\*\/|\/\*\*?|#|\/\/)$/;

/** A line worth tracking: not blank, not punctuation only, not a bare keyword or comment marker. */
export function isSignificant(line: string): boolean {
  const t = line.trim();
  return t.length >= 4 && !TRIVIAL.test(t);
}

const DIFF_FILE = /^\+\+\+ (?:b\/)?(.+?)\s*$/;

/**
 * Added lines per file from a unified diff (`git diff -U0 A B`). Deleted files (`+++ /dev/null`)
 * and binary files add nothing.
 */
export function parseAddedLines(diff: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  let current: string[] | null = null;
  for (const line of diff.split("\n")) {
    if (line.startsWith("+++ ")) {
      const m = DIFF_FILE.exec(line);
      const path = m?.[1];
      current = path && path !== "/dev/null" ? [] : null;
      if (current && path) out.set(path, current);
      continue;
    }
    if (line.startsWith("diff --git ")) current = null;
    else if (current && line.startsWith("+")) current.push(line.slice(1));
  }
  return out;
}

function counts(lines: readonly string[]): Map<string, number> {
  const m = new Map<string, number>();
  for (const l of lines) {
    const t = l.trim();
    m.set(t, (m.get(t) ?? 0) + 1);
  }
  return m;
}

/** How many of the change's significant added lines are still in their file at the horizon. */
export function measureSurvival(input: SurvivalInput): SurvivalSample {
  let added = 0;
  let kept = 0;
  for (const [path, lines] of input.added) {
    const sig = lines.filter(isSignificant);
    if (sig.length === 0) continue;
    added += sig.length;
    const text = input.later.get(path);
    if (text == null) continue;
    const pool = counts(text.split("\n"));
    for (const l of sig) {
      const t = l.trim();
      const n = pool.get(t) ?? 0;
      if (n > 0) {
        kept++;
        pool.set(t, n - 1);
      }
    }
  }
  return { added, kept, rate: added === 0 ? null : kept / added };
}

export type SurvivalVerdict = "survived" | "rewritten" | "too-small" | "unmeasured";

/** How one merged, unreverted change is labelled from its survival sample. */
export function survivalVerdict(
  s: SurvivalSample | null,
  rule: { readonly minRate: number; readonly minLines: number } = SURVIVAL_RULE,
): SurvivalVerdict {
  if (s === null || s.rate === null) return "unmeasured";
  if (s.added < rule.minLines) return "too-small";
  return s.rate >= rule.minRate ? "survived" : "rewritten";
}
