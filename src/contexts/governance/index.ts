export {
  type BriefOptions,
  briefInputs,
  type Guidance,
  loadGuidance,
} from "./application/guidance";
export {
  BRIEF_LIMITS,
  buildChecklist,
  type ChecklistItem,
  renderBrief,
  renderChecklist,
} from "./domain/brief";
export {
  DOC_ROOTS,
  type DocKind,
  docKindOf,
  type GovernanceDoc,
  inForce,
  parseDoc,
} from "./domain/doc";
export { globMatch } from "./domain/glob";
export {
  type Lesson,
  type LessonContext,
  lessonActive,
  parseLesson,
  type ScoredLesson,
  selectLessons,
} from "./domain/lesson";
export { type Proposal, type ProposalInput, proposeLesson } from "./domain/propose";
export type { DocSource, RepoDocs } from "./ports";
