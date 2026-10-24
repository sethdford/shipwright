// Bounds and cleans the text a classifier sees. This is the only place input limits are applied,
// so the domain rules can assume short, bounded lines.

/** Matches bash's `tail -200` in daemon-failure.sh (classify_failure). */
export const MAX_EVIDENCE_LINES = 200;
/** A single line longer than this is truncated. A 1 MB JSON line must not reach the regexes whole. */
export const MAX_EVIDENCE_LINE_CHARS = 4096;

// Lines the pipeline's model writes as analysis, or progress markers. Their prose ("accurate
// limits", "401 unauthorized" in a diagnosis) is not evidence of what failed, and a model must not be
// able to change a failure's class or stop the deterministic-failure check by writing it.
const MODEL_PROSE =
  /^\s*(?:[✓⚠]\s*)?(?:Failure analyzed|Failure diagnosis|Analyzing failure)\b|^\s*▸/i;

/** The last MAX_EVIDENCE_LINES lines, each cut to MAX_EVIDENCE_LINE_CHARS, model prose removed. */
export function boundEvidence(text: string): string {
  return text
    .split("\n")
    .slice(-MAX_EVIDENCE_LINES)
    .map((line) => line.slice(0, MAX_EVIDENCE_LINE_CHARS))
    .filter((line) => !MODEL_PROSE.test(line))
    .join("\n");
}
