import type { Lesson } from "./lesson";

export interface ProposalInput {
  readonly failureClass: string;
  readonly fingerprint: string;
  /** Where the failure came from: a run URL or id. Written to the lesson as `source`. */
  readonly source: string;
  /** The failing log. Only its last non-empty lines are kept, as evidence. */
  readonly log: string;
}

export type Proposal =
  | {
      readonly kind: "draft";
      readonly id: string;
      readonly path: string;
      readonly markdown: string;
    }
  | { readonly kind: "duplicate"; readonly id: string; readonly path: string };

const EVIDENCE_LINES = 20;
const EVIDENCE_CHARS = 2000;

export function nextLessonId(existing: readonly Pick<Lesson, "id">[]): string {
  let max = 0;
  for (const l of existing) {
    const n = /^L-(\d+)$/.exec(l.id)?.[1];
    if (n !== undefined) max = Math.max(max, Number(n));
  }
  return `L-${String(max + 1).padStart(4, "0")}`;
}

export function evidenceExcerpt(log: string): string {
  const lines = log
    .replace(/\r\n/g, "\n")
    .split("\n")
    .filter((l) => l.trim().length > 0);
  const tail = lines.slice(-EVIDENCE_LINES).join("\n");
  const cut = tail.length > EVIDENCE_CHARS ? tail.slice(tail.length - EVIDENCE_CHARS) : tail;
  // A fence inside the evidence would end the code block early.
  return cut.replace(/```/g, "'''");
}

function oneLine(text: string): string {
  return text
    .replace(/[\r\n]+/g, " ")
    .replace(/"/g, "'")
    .trim();
}

function render(id: string, input: ProposalInput): string {
  return [
    "---",
    `id: ${id}`,
    "status: proposed",
    `failure_class: ${input.failureClass}`,
    `fingerprint: ${input.fingerprint}`,
    "applies_to: []",
    "keywords: []",
    `source: "${oneLine(input.source)}"`,
    'hypothesis: "TODO: what should change in later runs if agents follow this rule"',
    "---",
    "# TODO: a short title",
    "",
    "TODO: one rule an agent can follow before it builds. Say what to do, not what went wrong.",
    "",
    "## Evidence",
    "",
    "```text",
    evidenceExcerpt(input.log),
    "```",
    "",
  ].join("\n");
}

/**
 * Drafts a lesson from one classified failure. It is `proposed`: no agent sees it until a person writes the rule
 * and the hypothesis and merges it as `active` (ADR-0010). A failure whose fingerprint a lesson already covers
 * (in any status) is a duplicate, so one failure never yields two drafts.
 */
export function proposeLesson(existing: readonly Lesson[], input: ProposalInput): Proposal {
  const dup = existing.find((l) => l.fingerprint === input.fingerprint);
  if (dup) return { kind: "duplicate", id: dup.id, path: dup.path };
  const id = nextLessonId(existing);
  const path = `.shipwright/lessons/${id}.md`;
  return { kind: "draft", id, path, markdown: render(id, input) };
}
