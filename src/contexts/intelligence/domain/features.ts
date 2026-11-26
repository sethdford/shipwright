/**
 * Features of an issue that the router reads. Deterministic text features only: the model's own
 * estimate of difficulty is never an input (ADR-0009 rule 2). Research on coding agents finds that
 * prompt-only signals predict success weakly (held-out AUC about 0.56 in Scrouting, 2026), so these
 * set a prior and the run history corrects it (see difficulty.ts).
 */

export const TIERS = ["trivial", "small", "medium", "large", "xl"] as const;
export type Tier = (typeof TIERS)[number];

export const ISSUE_KINDS = [
  "docs",
  "chore",
  "bug",
  "feature",
  "refactor",
  "security",
  "unknown",
] as const;
export type IssueKind = (typeof ISSUE_KINDS)[number];

export interface IssueText {
  readonly title: string;
  readonly body: string;
  readonly labels: readonly string[];
}

export interface IssueFeatures {
  readonly kind: IssueKind;
  readonly words: number;
  /** Distinct file paths named in the issue. */
  readonly paths: number;
  /** Checklist items (`- [ ]`), the usual shape of acceptance criteria. */
  readonly criteria: number;
  readonly stackTrace: boolean;
  /** A size a person put on the issue (`size/M`, `difficulty: large`, ...). */
  readonly sizeLabel?: Tier;
  readonly easySignals: readonly string[];
  readonly hardSignals: readonly string[];
  /** Named paths in areas where a wrong change is costly (workflows, auth, migrations, ...). */
  readonly riskyPaths: readonly string[];
}

const KIND_LABELS: readonly [RegExp, IssueKind][] = [
  [/^(security|vulnerability|cve)\b/, "security"],
  [/^(docs?|documentation)\b/, "docs"],
  [/^(chore|ci|build|deps|dependencies|maintenance)\b/, "chore"],
  [/^(refactor|tech[- ]debt|cleanup)\b/, "refactor"],
  [/^(bug|defect|regression|fix)\b/, "bug"],
  [/^(feature|enhancement|feat)\b/, "feature"],
];

const KIND_TITLES: readonly [RegExp, IssueKind][] = [
  [/^(security|sec)(\(|:|\s)/, "security"],
  [/^docs?(\(|:|\s)/, "docs"],
  [/^(chore|ci|build|deps)(\(|:|\s)/, "chore"],
  [/^refactor(\(|:|\s)/, "refactor"],
  [/^(fix|bug)(\(|:|\s)/, "bug"],
  [/^(feat|feature)(\(|:|\s)/, "feature"],
];

const SIZE_WORDS: Readonly<Record<string, Tier>> = {
  xs: "trivial",
  trivial: "trivial",
  s: "small",
  small: "small",
  easy: "small",
  m: "medium",
  medium: "medium",
  l: "large",
  large: "large",
  hard: "large",
  xl: "xl",
  xxl: "xl",
  epic: "xl",
};

export const EASY_SIGNALS = [
  "typo",
  "rename",
  "wording",
  "readme",
  "comment",
  "bump",
  "log message",
];
export const HARD_SIGNALS = [
  "migrate",
  "migration",
  "architecture",
  "redesign",
  "concurrency",
  "race condition",
  "deadlock",
  "performance",
  "across all",
  "every command",
  "backwards compat",
  "breaking change",
  "distributed",
  "flaky",
];

const RISKY_PATH =
  /(^|\/)(\.github\/workflows|auth|migrations?|security|secrets?|billing|payments?)(\/|$)/;
const PATH_TOKEN =
  /(?:^|[\s`'"(])((?:[\w.-]+\/)+[\w.-]+\.[a-z0-9]{1,6})(?=$|[\s`'"),:;]|\.(?:\s|$))/gim;
const TRACE_LINE =
  /^\s*(at \S+ \(|File "[^"]+", line \d+|Traceback \(most recent call last\)|panic: )/m;

function kindOf(issue: IssueText): IssueKind {
  for (const label of issue.labels.map((l) => l.toLowerCase().trim())) {
    for (const [re, kind] of KIND_LABELS) if (re.test(label)) return kind;
  }
  const title = issue.title.toLowerCase().trim();
  for (const [re, kind] of KIND_TITLES) if (re.test(title)) return kind;
  return "unknown";
}

/** `size/M`, `size: L`, `difficulty:hard`, `effort/xs`: the first one wins. */
export function sizeFromLabels(labels: readonly string[]): Tier | undefined {
  for (const label of labels) {
    const m = /^(?:size|difficulty|effort|complexity)\s*[/:]\s*([a-z]+)$/i.exec(label.trim());
    const tier = m ? SIZE_WORDS[(m[1] ?? "").toLowerCase()] : undefined;
    if (tier !== undefined) return tier;
  }
  return undefined;
}

function namedPaths(text: string): readonly string[] {
  const found = new Set<string>();
  for (const m of text.matchAll(PATH_TOKEN)) if (m[1] !== undefined) found.add(m[1]);
  return [...found];
}

const signalsIn = (text: string, words: readonly string[]): readonly string[] =>
  words.filter((w) => new RegExp(`\\b${w}`, "i").test(text));

export function extractFeatures(issue: IssueText): IssueFeatures {
  const text = `${issue.title}\n${issue.body}`;
  const paths = namedPaths(text);
  const size = sizeFromLabels(issue.labels);
  return {
    kind: kindOf(issue),
    words: text.split(/\s+/).filter((w) => w.length > 0).length,
    paths: paths.length,
    criteria: (issue.body.match(/^\s*[-*] \[[ xX]\]/gm) ?? []).length,
    stackTrace: TRACE_LINE.test(issue.body),
    ...(size === undefined ? {} : { sizeLabel: size }),
    easySignals: signalsIn(text, EASY_SIGNALS),
    hardSignals: signalsIn(text, HARD_SIGNALS),
    riskyPaths: paths.filter((p) => RISKY_PATH.test(p)),
  };
}
