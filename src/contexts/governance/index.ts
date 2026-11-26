export {
  type BriefOptions,
  briefInputs,
  type Guidance,
  loadGuidance,
} from "./application/guidance";
export { classifyRuns, type MinedDraft, mineDrafts, type RunLog } from "./application/learn";
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
  ruleText,
  sectionText,
} from "./domain/doc";
export { globMatch } from "./domain/glob";
export {
  type Lesson,
  type LessonContext,
  lessonActive,
  lessonEligible,
  parseLesson,
  type ScoredLesson,
  selectLessons,
} from "./domain/lesson";
export { DEFAULT_MINE, LEARNABLE_CLASSES, type MineOptions } from "./domain/mine";
export {
  decidePromotion,
  MIN_TRIAL_CASES,
  type Promotion,
  parseTrialVerdict,
  type TrialVerdict,
} from "./domain/promote";
export { type Proposal, type ProposalInput, proposeLesson } from "./domain/propose";
export {
  applyReflection,
  needsReflection,
  parseReflection,
  type Reflection,
  reflectionPrompt,
} from "./domain/reflect";
export type { DocSource, RepoDocs } from "./ports";
