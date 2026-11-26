import type { AdapterError } from "../../../shared/kernel/ports";
import { err, ok, type Result } from "../../../shared/kernel/result";
import { DOC_KINDS, DOC_ROOTS, docKindOf, type GovernanceDoc, parseDoc } from "../domain/doc";
import { type Lesson, type LessonContext, parseLesson, selectLessons } from "../domain/lesson";
import type { DocSource, RepoDocs } from "../ports";

export interface Guidance {
  readonly docs: readonly GovernanceDoc[];
  readonly lessons: readonly Lesson[];
}

const MAX_FILES = 200;

/**
 * Reads every governance document and lesson from the source. Fails closed: a file that is listed but cannot be
 * read is an error, never a silently shorter brief. At most 200 files are read; the rest are ignored in path order.
 */
export async function loadGuidance(
  repo: RepoDocs,
  source: DocSource,
): Promise<Result<Guidance, AdapterError>> {
  const roots = DOC_KINDS.flatMap((k) => DOC_ROOTS[k]);
  const listed = await repo.list(source, roots);
  if (!listed.ok) return listed;
  const paths = [...listed.value]
    .filter((p) => docKindOf(p) !== null)
    .sort()
    .slice(0, MAX_FILES);
  const docs: GovernanceDoc[] = [];
  const lessons: Lesson[] = [];
  for (const path of paths) {
    const kind = docKindOf(path);
    const raw = await repo.read(source, path);
    if (!raw.ok) return err({ kind: raw.error.kind, message: `${path}: ${raw.error.message}` });
    if (kind === "lesson") lessons.push(parseLesson(path, raw.value));
    else if (kind !== null) docs.push(parseDoc(kind, path, raw.value));
  }
  return ok({ docs, lessons });
}

export interface BriefOptions {
  readonly lessons: boolean;
  readonly governance: boolean;
  readonly context: LessonContext;
}

/** What goes into a prompt: the documents in force (when governance is on) and the lessons that fit (when on). */
export function briefInputs(g: Guidance, opts: BriefOptions) {
  return {
    docs: opts.governance ? g.docs : [],
    lessons: opts.lessons ? selectLessons(g.lessons, opts.context) : [],
  };
}
