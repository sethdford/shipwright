/**
 * Review triage for the PR steward (ADR-0017): which comments on a PR the steward should act on.
 * Comments are untrusted text. Only people with write access to the repository (OWNER, MEMBER,
 * COLLABORATOR) and named review bots can steer a fix round; anything else is ignored, so a
 * drive-by commenter cannot instruct the fixer. Pure: comments come in as data.
 */

export type CommentKind = "inline" | "review" | "conversation";
export type CommentIntent = "change" | "question";

export interface PrComment {
  readonly id: number;
  readonly kind: CommentKind;
  readonly author: string;
  /** GitHub's author_association: OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR, NONE, ... */
  readonly association: string;
  readonly body: string;
  /** Inline comments: the file and line; the thread root's id when this is a reply. */
  readonly path: string | null;
  readonly line: number | null;
  readonly inReplyTo: number | null;
  /** Inline comments GitHub marks outdated (the line changed since) are left alone. */
  readonly outdated: boolean;
  /** Review bodies: APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED. */
  readonly reviewState: string | null;
  readonly createdAt: string;
  /** GitHub's user.type is "Bot" (some bots' logins have no [bot] suffix). */
  readonly isBot?: boolean;
}

export interface ActionableComment {
  readonly id: number;
  /** Inline comments: the thread's first comment (GitHub replies only to that one); else the id. */
  readonly threadId: number;
  readonly kind: CommentKind;
  readonly author: string;
  readonly path: string | null;
  readonly line: number | null;
  readonly body: string;
  readonly intent: CommentIntent;
}

export interface ReviewPolicy {
  /** The login the steward posts as: its replies carry STEWARD_MARK and are never acted on. */
  readonly self: string;
  /** Bot logins whose reviews count (for example claude[bot]). Lowercase. */
  readonly bots: ReadonlySet<string>;
  /** Comment ids already handled in an earlier round (answered, declined or given up on). */
  readonly handled: ReadonlySet<number>;
  /**
   * Lowercase logins with write, maintain or admin permission on the repository. REST's
   * author_association is not enough on its own: MEMBER is any member of the owning org and
   * COLLABORATOR includes read-only collaborators. When given, a human must be in this set too.
   */
  readonly writers?: ReadonlySet<string>;
}

/** Every reply the steward posts carries this, followed by ` reply-to:<id>`. */
export const STEWARD_MARK = "<!-- shipwright-steward";

export const DEFAULT_REVIEW_BOTS: readonly string[] = [
  "claude[bot]",
  "copilot-pull-request-reviewer[bot]",
  "coderabbitai[bot]",
  "cursor[bot]",
  "chatgpt-codex-connector[bot]",
  // REST reports Copilot's reviewer as the Bot-typed login "Copilot" on some endpoints.
  "copilot",
];

const TRUSTED_ASSOCIATIONS = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);

export function isTrustedAuthor(c: PrComment, policy: ReviewPolicy): boolean {
  const login = c.author.toLowerCase();
  if (login.endsWith("[bot]") || c.isBot === true) return policy.bots.has(login);
  if (!TRUSTED_ASSOCIATIONS.has(c.association.toUpperCase())) return false;
  return policy.writers === undefined || policy.writers.has(login);
}

/** Human authors who pass the association check: the logins whose permission must be looked up. */
export function candidateWriters(comments: readonly PrComment[]): string[] {
  const out = new Set<string>();
  for (const c of comments) {
    const login = c.author.toLowerCase();
    if (login.endsWith("[bot]") || c.isBot === true) continue;
    if (TRUSTED_ASSOCIATIONS.has(c.association.toUpperCase())) out.add(login);
  }
  return [...out];
}

/** Ids the steward has already replied to, read from its own marked replies (by `self` only). */
export function repliedIds(comments: readonly PrComment[], self: string): Set<number> {
  const ids = new Set<number>();
  const re = /<!-- shipwright-steward reply-to:(\d+(?:,\d+)*) -->/g;
  for (const c of comments) {
    if (c.author !== self) continue;
    for (const m of c.body.matchAll(re)) {
      for (const id of (m[1] ?? "").split(",")) ids.add(Number(id));
    }
  }
  return ids;
}

/** Text that asks for nothing: approvals, thanks, a clean bot review, pipeline markers. */
const NO_ASK =
  /^\s*(lgtm|looks good|approved?|thanks?|thank you|ship it|nice|great|👍|🚀|✅)[\s.!]*$|no issues found|^\s*$/i;
const PIPELINE_MARKER = /SHIPWRIGHT-[A-Z-]+:|<!-- shipwright/i;

export function asksForSomething(body: string): boolean {
  return !NO_ASK.test(body.trim()) && !PIPELINE_MARKER.test(body);
}

/** A question unless it also says to change something; the fixer makes the final call. */
export function intentOf(body: string): CommentIntent {
  const imperative =
    /\b(please|should|must|need(s)? to|change|rename|remove|add|fix|use|move|replace|drop|avoid|don't|do not)\b/i;
  const text = body.trim();
  return text.endsWith("?") && !imperative.test(text) ? "question" : "change";
}

function inScope(c: PrComment): boolean {
  if (c.kind === "inline") return !c.outdated;
  if (c.kind === "review")
    return c.reviewState === "CHANGES_REQUESTED" || c.reviewState === "COMMENTED";
  return true;
}

/**
 * The comments to act on this round: in scope, from a trusted author, not the steward's own, not
 * already replied to or handled, and asking for something. Inline replies inside a thread count
 * only when they are the newest word in that thread from a trusted author other than the steward.
 */
export function actionableComments(
  comments: readonly PrComment[],
  policy: ReviewPolicy,
): ActionableComment[] {
  const replied = repliedIds(comments, policy.self);
  const latestInThread = newestPerThread(comments, policy);
  return comments
    .filter((c) => !c.body.includes(STEWARD_MARK))
    .filter((c) => inScope(c) && isTrustedAuthor(c, policy) && asksForSomething(c.body))
    .filter((c) => !replied.has(c.id) && !policy.handled.has(c.id))
    .filter((c) => c.kind !== "inline" || latestInThread.get(threadOf(c)) === c.id)
    .map((c) => ({
      id: c.id,
      threadId: threadOf(c),
      kind: c.kind,
      author: c.author,
      path: c.path,
      line: c.line,
      body: c.body,
      intent: intentOf(c.body),
    }));
}

const threadOf = (c: PrComment): number => c.inReplyTo ?? c.id;

/**
 * For each inline thread, the id of its newest in-scope comment from a trusted author other than
 * the steward. Untrusted or outdated replies are ignored, so they cannot silence a maintainer.
 */
function newestPerThread(
  comments: readonly PrComment[],
  policy: ReviewPolicy,
): Map<number, number> {
  const out = new Map<number, { id: number; at: string }>();
  for (const c of comments) {
    if (c.kind !== "inline" || (c.author === policy.self && c.body.includes(STEWARD_MARK)))
      continue;
    if (!inScope(c) || !isTrustedAuthor(c, policy)) continue;
    const prev = out.get(threadOf(c));
    if (!prev || c.createdAt >= prev.at) out.set(threadOf(c), { id: c.id, at: c.createdAt });
  }
  return new Map([...out].map(([t, v]) => [t, v.id]));
}
