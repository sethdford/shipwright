// Issue intake caps (spec §6.2 "Patrol hygiene"): a cap on open auto-filed issues and an exact
// title-fingerprint dedupe. Semantic dedupe (a decide<T> call) replaces the fingerprint later.

export interface IssueSummary {
  readonly number: number;
  readonly title: string;
  readonly labels: readonly string[];
}

export interface IntakePolicy {
  /** Label that marks issues filed by automation (patrol). */
  readonly autoLabel: string;
  /** No new auto-filed issue while this many are open. */
  readonly maxOpenAuto: number;
}

export const DEFAULT_INTAKE_POLICY: IntakePolicy = { autoLabel: "auto-patrol", maxOpenAuto: 25 };

export interface IntakeVerdict {
  readonly allowed: boolean;
  readonly openAuto: number;
  readonly cap: number;
  /** An open issue with the same title fingerprint, if any. */
  readonly duplicateOf: number | null;
}

/**
 * NFKC-normalised, lowercase, every run of numbers as 0, everything but letters and numbers
 * (punctuation, whitespace, control and bidi characters) as one space. Titles are untrusted.
 */
export function titleFingerprint(title: string): string {
  return title
    .normalize("NFKC")
    .toLowerCase()
    .replace(/\p{N}+/gu, "0")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

export function evaluateIntake(
  open: readonly IssueSummary[],
  candidateTitle: string | null,
  policy: IntakePolicy = DEFAULT_INTAKE_POLICY,
): IntakeVerdict {
  const openAuto = open.filter((i) => i.labels.includes(policy.autoLabel)).length;
  const fingerprint = candidateTitle === null ? "" : titleFingerprint(candidateTitle);
  const duplicate = fingerprint
    ? open.find((i) => titleFingerprint(i.title) === fingerprint)
    : undefined;
  return {
    allowed: openAuto < policy.maxOpenAuto && duplicate === undefined,
    openAuto,
    cap: policy.maxOpenAuto,
    duplicateOf: duplicate?.number ?? null,
  };
}

export function describeIntake(v: IntakeVerdict): string {
  const count = `${v.openAuto} of ${v.cap} open auto-patrol issues`;
  if (v.duplicateOf !== null) return `${count}; duplicate of #${v.duplicateOf}`;
  return v.openAuto >= v.cap ? `${count} (cap reached)` : count;
}
