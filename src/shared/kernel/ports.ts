import type { ZodType } from "zod";
import type { Result } from "./result";

// ── Processes ────────────────────────────────────────────────────────────────
export interface ProcessRequest {
  readonly argv: readonly string[];
  readonly cwd?: string;
  readonly env?: Readonly<Record<string, string>>;
  readonly stdin?: string;
  readonly timeoutMs?: number;
}
export interface ProcessResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
  readonly timedOut: boolean;
}
export interface ProcessRunner {
  run(request: ProcessRequest): Promise<ProcessResult>;
}

// ── Locations (rule F8: always injected, never read from the real machine in tests) ─
export interface Paths {
  readonly home: string;
  readonly stateDir: string;
  readonly tmuxSocket: string;
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
  list(runId: string): EventRecord[];
}

// ── Terminal (tmux) ──────────────────────────────────────────────────────────
export interface Terminal {
  newSession(name: string, cwd: string): Promise<Result<void, string>>;
  listSessions(): Promise<string[]>;
  killSession(name: string): Promise<void>;
}

// ── Version control and issues ───────────────────────────────────────────────
export interface Vcs {
  headSha(cwd: string): Promise<Result<string, string>>;
  currentBranch(cwd: string): Promise<Result<string, string>>;
}
export interface Issue {
  readonly number: number;
  readonly title: string;
  readonly body: string;
  readonly labels: readonly string[];
}
export interface IssueTracker {
  getIssue(number: number): Promise<Result<Issue, string>>;
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
  | "execution";

export interface AgentFailure {
  readonly kind: AgentFailureKind;
  readonly message: string;
  readonly costUsd: number;
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
  readonly costUsd: number;
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
  readonly costUsd: number;
  readonly turns: number;
  readonly sessionId: string;
}

export interface AgentRunner {
  decide<T>(request: DecideRequest<T>): Promise<Result<Decision<T>, AgentFailure>>;
  runTask(spec: TaskSpec): Promise<Result<TaskOutcome, AgentFailure>>;
}
