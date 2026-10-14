import type { ZodType } from "zod";
import type { Result } from "./result";

// ── Errors from external systems ─────────────────────────────────────────────
// Classified so callers decide retry/backoff on `kind`, never by matching message text.
export type AdapterErrorKind = "not_found" | "auth" | "transient" | "failed";
export interface AdapterError {
  readonly kind: AdapterErrorKind;
  readonly message: string;
}

// ── Processes ────────────────────────────────────────────────────────────────
export interface ProcessRequest {
  readonly argv: readonly string[];
  readonly cwd?: string;
  /** Replaces the child environment entirely. Omit to inherit the parent's environment. When replacing, pass PATH explicitly. */
  readonly env?: Readonly<Record<string, string>>;
  readonly stdin?: string;
  readonly timeoutMs?: number;
}
/** Check `timedOut` before `exitCode`: a timed-out child may still report 0. */
export interface ProcessResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
  readonly timedOut: boolean;
}
export interface ProcessRunner {
  /** Throws if the program cannot be started (for example, it is not installed). */
  run(request: ProcessRequest): Promise<ProcessResult>;
}

// ── Locations (rule F8: always injected, never read from the real machine in tests) ─
export interface Paths {
  readonly home: string;
  readonly stateDir: string;
  /** tmux socket *name* for `tmux -L`, not a filesystem path. */
  readonly tmuxSocketName: string;
}

// ── Events ───────────────────────────────────────────────────────────────────
export interface EventRecord {
  readonly runId: string;
  readonly type: string;
  readonly at: string;
  readonly data: Readonly<Record<string, unknown>>;
}
export interface EventLog {
  append(event: EventRecord): void;
  /** Events for one run, oldest first. */
  list(runId: string): readonly EventRecord[];
}

// ── Terminal (tmux) ──────────────────────────────────────────────────────────
export interface Terminal {
  newSession(name: string, cwd: string): Promise<Result<void, AdapterError>>;
  /** No server running is not an error: it yields an empty list. */
  listSessions(): Promise<Result<readonly string[], AdapterError>>;
  /** Idempotent: an absent session or server is ok. */
  killSession(name: string): Promise<Result<void, AdapterError>>;
}

// ── Version control and issues ───────────────────────────────────────────────
export interface Vcs {
  headSha(cwd: string): Promise<Result<string, AdapterError>>;
  currentBranch(cwd: string): Promise<Result<string, AdapterError>>;
}
export interface Issue {
  readonly number: number;
  readonly title: string;
  readonly body: string;
  readonly state: "open" | "closed";
  readonly author: string;
  readonly labels: readonly string[];
}
export interface IssueTracker {
  getIssue(number: number): Promise<Result<Issue, AdapterError>>;
}

// ── Agent runtime (rule F6: implemented only in src/adapters/agent) ──────────
export type Effort = "low" | "medium" | "high" | "xhigh" | "max";

export type AgentFailureKind =
  | "refusal"
  | "max_turns"
  | "budget"
  | "schema"
  | "timeout"
  | "aborted"
  | "transient"
  | "auth"
  | "execution";

/** What one agent call consumed; callers write it to the run ledger (spec §5). */
export interface AgentUsage {
  readonly costUsd: number;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly durationMs: number;
}

export interface AgentFailure {
  readonly kind: AgentFailureKind;
  readonly message: string;
  readonly usage: AgentUsage;
  /** Present when a session was created, so max_turns/budget failures can be resumed. */
  readonly sessionId?: string;
}

export interface DecideRequest<T> {
  /** Trusted instructions written by Shipwright. Becomes the system prompt. */
  readonly instructions: string;
  /** Untrusted input (issue text, PR bodies). Passed only as data. */
  readonly data: string;
  readonly schema: ZodType<T>;
  readonly model: string;
  readonly effort: Effort;
  readonly maxBudgetUsd: number;
  readonly timeoutMs: number;
}
export interface Decision<T> {
  readonly value: T;
  readonly usage: AgentUsage;
}

export interface TaskSpec {
  readonly prompt: string;
  readonly cwd: string;
  readonly model: string;
  readonly effort: Effort;
  /** Tools auto-approved for this task; everything else is denied. */
  readonly allowedTools: readonly string[];
  readonly maxTurns: number;
  readonly maxBudgetUsd: number;
  readonly timeoutMs: number;
  readonly signal?: AbortSignal;
}
export interface TaskOutcome {
  readonly summary: string;
  readonly usage: AgentUsage;
  readonly turns: number;
  readonly sessionId: string;
}

export interface AgentRunner {
  decide<T>(request: DecideRequest<T>): Promise<Result<Decision<T>, AgentFailure>>;
  runTask(spec: TaskSpec): Promise<Result<TaskOutcome, AgentFailure>>;
}
