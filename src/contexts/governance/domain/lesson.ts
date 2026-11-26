import { type GovernanceDoc, parseDoc, ruleText } from "./doc";
import { metaList, metaString, parseFrontmatter } from "./frontmatter";
import { anyGlobMatches } from "./glob";

/** A rule learned from a run. Only `active` lessons reach an agent; a human makes a lesson active by merging it. */
export interface Lesson extends GovernanceDoc {
  readonly kind: "lesson";
  readonly failureClass?: string;
  readonly fingerprint?: string;
  readonly keywords: readonly string[];
  readonly hypothesis?: string;
  readonly source?: string;
}

export interface LessonContext {
  /** The issue title and body, or the goal: keywords are matched against it. */
  readonly text: string;
  readonly paths: readonly string[];
  readonly failureClass?: string;
  readonly fingerprint?: string;
}

export interface ScoredLesson {
  readonly lesson: Lesson;
  readonly score: number;
  readonly why: readonly string[];
}

export const MAX_LESSONS = 5;

function optional<K extends string>(key: K, value: string | undefined): Partial<Record<K, string>> {
  return value === undefined ? {} : ({ [key]: value } as Record<K, string>);
}

export function parseLesson(path: string, raw: string): Lesson {
  const doc = parseDoc("lesson", path, raw);
  const { meta } = parseFrontmatter(raw);
  return {
    ...doc,
    kind: "lesson",
    // The rule only: no title line, no Evidence or Evaluation section (those are for the reviewer, not the agent).
    text: ruleText(doc.text),
    keywords: metaList(meta, "keywords").map((k) => k.toLowerCase()),
    ...optional("failureClass", metaString(meta, "failure_class")),
    ...optional("fingerprint", metaString(meta, "fingerprint")),
    ...optional("hypothesis", metaString(meta, "hypothesis")),
    ...optional("source", metaString(meta, "source")),
  };
}

export function lessonActive(lesson: Pick<Lesson, "status">): boolean {
  return lesson.status === "active";
}

/** Active lessons, plus the proposed lessons named for a trial arm (ADR-0010 amendment). Retired ones never. */
export function lessonEligible(
  lesson: Pick<Lesson, "status" | "id">,
  trial: readonly string[],
): boolean {
  return lessonActive(lesson) || (lesson.status === "proposed" && trial.includes(lesson.id));
}

function hasTriggers(l: Lesson): boolean {
  return (
    l.appliesTo.length > 0 ||
    l.keywords.length > 0 ||
    l.failureClass !== undefined ||
    l.fingerprint !== undefined
  );
}

/** How well one lesson fits a run, with the reasons. A lesson with no triggers applies everywhere, weakly. */
export function scoreLesson(l: Lesson, ctx: LessonContext): ScoredLesson {
  if (!hasTriggers(l)) return { lesson: l, score: 1, why: ["repository-wide"] };
  const why: string[] = [];
  let score = 0;
  if (l.fingerprint !== undefined && l.fingerprint === ctx.fingerprint) {
    score += 5;
    why.push("same failure fingerprint");
  }
  if (l.failureClass !== undefined && l.failureClass === ctx.failureClass) {
    score += 3;
    why.push(`failure class ${l.failureClass}`);
  }
  if (l.appliesTo.length > 0 && anyGlobMatches(l.appliesTo, ctx.paths)) {
    score += 3;
    why.push("touches its paths");
  }
  const text = ctx.text.toLowerCase();
  const hits = l.keywords.filter((k) => k.length > 0 && text.includes(k));
  if (hits.length > 0) {
    score += Math.min(hits.length, 3);
    why.push(`mentions ${hits.slice(0, 3).join(", ")}`);
  }
  return { lesson: l, score, why };
}

/** The active lessons that fit this run, best first, at most `limit`. Ties keep id order, so output is stable. */
export function selectLessons(
  lessons: readonly Lesson[],
  ctx: LessonContext,
  limit: number = MAX_LESSONS,
  trial: readonly string[] = [],
): readonly ScoredLesson[] {
  return lessons
    .filter((l) => lessonEligible(l, trial))
    .map((l) => scoreLesson(l, ctx))
    .filter((s) => s.score > 0)
    .sort((a, b) => b.score - a.score || a.lesson.id.localeCompare(b.lesson.id))
    .slice(0, limit);
}
