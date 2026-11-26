/**
 * The PR steward's records between rounds (ADR-0017), read back from files the pipeline keeps in
 * its artifacts directory: the round history, and the comments a fix round was offered (from that
 * round's inspect report). Both are validated; a missing or unreadable history starts empty.
 */
import { z } from "zod";
import { EMPTY_HISTORY, type StewardHistory } from "./steward-policy";
import type { ActionableComment } from "./steward-reviews";

const History = z.object({
  rounds: z.number().int().min(0).default(0),
  fixedSignatures: z.array(z.array(z.string())).default([]),
  rerunChecks: z.array(z.string()).default([]),
  commentAttempts: z.record(z.string(), z.number().int().min(0)).default({}),
});

export function parseHistory(text: string): StewardHistory {
  if (!text.trim()) return EMPTY_HISTORY;
  try {
    const parsed = History.safeParse(JSON.parse(text));
    return parsed.success ? parsed.data : EMPTY_HISTORY;
  } catch {
    return EMPTY_HISTORY;
  }
}

const Offered = z.object({
  id: z.number().int().positive(),
  threadId: z.number().int().positive(),
  kind: z.enum(["inline", "review", "conversation"]),
  author: z.string(),
  path: z.string().nullable(),
  line: z.number().nullable(),
  body: z.string(),
  intent: z.enum(["change", "question"]),
});

const Report = z.object({ decision: z.object({ fixComments: z.array(Offered) }) });

/** The comments an inspect report offered the fix round, or an error message. */
export function offeredComments(text: string): ActionableComment[] | string {
  try {
    const parsed = Report.safeParse(JSON.parse(text));
    return parsed.success
      ? parsed.data.decision.fixComments
      : `not a steward report: ${parsed.error.issues[0]?.message ?? ""}`;
  } catch (e) {
    return `not a steward report: ${e instanceof Error ? e.message : String(e)}`;
  }
}
