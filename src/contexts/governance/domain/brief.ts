import { type DocKind, type GovernanceDoc, inForce } from "./doc";
import { anyGlobMatches } from "./glob";
import type { ScoredLesson } from "./lesson";

/** Per-document and total limits, in characters. The brief rides in a prompt beside 64 KiB of project memory. */
export const BRIEF_LIMITS = { policy: 1500, standard: 1500, adr: 700, total: 16_000 } as const;

const TRUNCATED = "\n\n[governance brief truncated; read the files under docs/ for the rest]";

const SECTIONS: readonly { kind: Exclude<DocKind, "lesson">; heading: string }[] = [
  { kind: "policy", heading: "Policies" },
  { kind: "standard", heading: "Standards" },
  { kind: "adr", heading: "Architecture decisions (in force)" },
];

function clip(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max).trimEnd()} …`;
}

function scope(doc: GovernanceDoc): string {
  return doc.appliesTo.length > 0 ? ` (applies to: ${doc.appliesTo.join(", ")})` : "";
}

/** True when a document governs at least one of these paths. With no paths known, every document applies. */
export function appliesToAny(doc: GovernanceDoc, paths: readonly string[]): boolean {
  if (doc.appliesTo.length === 0 || paths.length === 0) return true;
  return anyGlobMatches(doc.appliesTo, paths);
}

function docSection(
  docs: readonly GovernanceDoc[],
  kind: Exclude<DocKind, "lesson">,
  heading: string,
) {
  const mine = docs.filter((d) => d.kind === kind);
  if (mine.length === 0) return "";
  const entries = mine.map(
    (d) =>
      `### ${d.id}: ${d.title}${scope(d)}\nSource: ${d.path}\n\n${clip(d.text, BRIEF_LIMITS[kind])}`,
  );
  return `## ${heading}\n\n${entries.join("\n\n")}`;
}

function lessonSection(lessons: readonly ScoredLesson[]): string {
  if (lessons.length === 0) return "";
  const rows = lessons.map(({ lesson: l }) => {
    const why = l.hypothesis === undefined ? "" : ` Why: ${l.hypothesis}`;
    return `- [${l.id}] ${clip(l.text.replace(/\n+/g, " "), 400)}${why}`;
  });
  return `## Lessons from earlier runs\n\nEach was learned from a failed run and approved by a maintainer.\n\n${rows.join("\n")}`;
}

/**
 * The governance brief for a build or review agent: the policies, standards and accepted ADRs in force, then the
 * lessons that fit the run. Empty when the repository has none, so a caller can leave the section out.
 */
export function renderBrief(
  docs: readonly GovernanceDoc[],
  lessons: readonly ScoredLesson[],
  paths: readonly string[] = [],
): string {
  const live = docs.filter((d) => d.kind !== "lesson" && inForce(d) && appliesToAny(d, paths));
  const parts = [
    ...SECTIONS.map((s) => docSection(live, s.kind, s.heading)),
    lessonSection(lessons),
  ].filter((p) => p.length > 0);
  if (parts.length === 0) return "";
  const head =
    "# Repository governance\n\nThese are the rules this repository has decided. Follow them. If your change has to " +
    "break one, say so in the pull request and name its id.";
  const text = [head, ...parts].join("\n\n");
  return text.length <= BRIEF_LIMITS.total
    ? text
    : `${text.slice(0, BRIEF_LIMITS.total - TRUNCATED.length)}${TRUNCATED}`;
}

export interface ChecklistItem {
  readonly id: string;
  readonly kind: DocKind;
  readonly title: string;
  readonly path: string;
  /** "scoped" when the document names paths this change touches; "repository-wide" when it names none. */
  readonly reason: "scoped" | "repository-wide";
}

/** The rules a reviewer must check this change against: scoped documents first, then repository-wide policies. */
export function buildChecklist(
  docs: readonly GovernanceDoc[],
  changed: readonly string[],
): readonly ChecklistItem[] {
  const live = docs.filter((d) => d.kind !== "lesson" && inForce(d));
  const item = (d: GovernanceDoc, reason: ChecklistItem["reason"]): ChecklistItem => ({
    id: d.id,
    kind: d.kind,
    title: d.title,
    path: d.path,
    reason,
  });
  const scoped = live
    .filter((d) => d.appliesTo.length > 0 && anyGlobMatches(d.appliesTo, changed))
    .map((d) => item(d, "scoped"));
  const wide = live
    .filter((d) => d.appliesTo.length === 0 && d.kind !== "adr")
    .map((d) => item(d, "repository-wide"));
  return [...scoped, ...wide];
}

export function renderChecklist(items: readonly ChecklistItem[]): string {
  if (items.length === 0) return "";
  const rows = items.map((i) => `- [ ] ${i.id}: ${i.title} (${i.path})`);
  return [
    "## Governance checklist",
    "",
    "Check the diff against each rule below. For each one, say it complies, or name the violation and the line.",
    "",
    ...rows,
  ].join("\n");
}
