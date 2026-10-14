import type { Result } from "./result";

// Durability contract (spec §6.1, ADR-0005). Types plus one pure helper; no adapters here.
// Adapters: SQLite (Wave 1, mode M1) and Postgres (Wave 2, modes M2/M3). Each must pass
// src/testing/contracts/durability-contract.ts unchanged.

/** Proof of the current lease on one work item. `epoch` grows on every successful claim. */
export interface FenceToken {
  readonly workId: string;
  readonly epoch: number;
}

/**
 * Stable key for one external side effect, e.g. `run-42:pr:open`. Injective: each part escapes
 * `\` and `:` before joining, so `("a:b", "c")` and `("a", "b:c")` never share a key.
 */
export type IdempotencyKey = string & { readonly __brand: "IdempotencyKey" };
const escapePart = (part: string): string => part.replaceAll("\\", "\\\\").replaceAll(":", "\\:");
export const idempotencyKey = (first: string, ...rest: readonly string[]): IdempotencyKey =>
  [first, ...rest].map(escapePart).join(":") as IdempotencyKey;

export type DurabilityErrorKind =
  | "stale_fence"
  | "duplicate"
  | "not_found"
  | "transient"
  | "failed";
export interface DurabilityError {
  readonly kind: DurabilityErrorKind;
  readonly message: string;
}
type Durable<T> = Promise<Result<T, DurabilityError>>;
type Json = Readonly<Record<string, unknown>>;

// ── Work queue: atomic claim with lease and fence ────────────────────────────
export interface NewWorkItem {
  readonly pool: string;
  /** The run this item advances. A run has at most one unfinished item (else `duplicate`). */
  readonly runId: string;
  /** Enqueueing while an unfinished item has the same key fails with `duplicate`. */
  readonly dedupeKey: string;
  readonly payload: Json;
  /**
   * Epoch milliseconds before which the item is not claimable. This is the timer wake: a run that
   * sleeps or retries later enqueues its next item with `notBefore`.
   */
  readonly notBefore?: number;
}
export interface Lease {
  readonly fence: FenceToken;
  readonly runId: string;
  readonly workerId: string;
  readonly expiresAt: number;
  readonly payload: Json;
}
export interface ClaimLimits {
  /**
   * Per-pool concurrency: no claim while `pool` already holds this many live leases. Counted inside
   * the claim transaction. Every claimer of a pool must pass the same value (it comes from config).
   */
  readonly maxActive?: number;
}
/** Both outcomes are terminal. Retry policy lives above the queue: enqueue a new item. */
export type WorkOutcome = "succeeded" | "failed";
export interface WorkQueue {
  /** Returns the new item's id. */
  enqueue(item: NewWorkItem): Durable<string>;
  /** Oldest ready, unleased (or lease-expired) item in `pool`; `null` when none or at the limit. */
  claim(
    pool: string,
    workerId: string,
    leaseMs: number,
    limits?: ClaimLimits,
  ): Durable<Lease | null>;
  heartbeat(fence: FenceToken, leaseMs: number): Durable<Lease>;
  /**
   * Finishes the item for good: it is never claimed again, its dedupe key and run are free for a
   * new item, and `outcome` is recorded. Completing twice fails `stale_fence`.
   */
  complete(fence: FenceToken, outcome: WorkOutcome): Durable<void>;
  /** The recorded outcome; `null` while unfinished; `not_found` for an unknown id. */
  outcome(workId: string): Durable<WorkOutcome | null>;
}

// ── Run journal: append-only, fenced ─────────────────────────────────────────
export interface JournalEntry {
  readonly runId: string;
  readonly seq: number;
  readonly type: string;
  readonly at: string;
  readonly data: Json;
}
export interface RunJournal {
  /**
   * Appends to the run of the fence's work item; the caller cannot name another run. Fails with
   * `stale_fence` unless `fence` is the live lease.
   */
  append(fence: FenceToken, entry: Omit<JournalEntry, "seq" | "runId">): Durable<JournalEntry>;
  /** Entries for one run in `seq` order, after `afterSeq` when given. */
  read(runId: string, afterSeq?: number): Durable<readonly JournalEntry[]>;
}

// ── Durable signals (approvals, cancel) ──────────────────────────────────────
export interface Signal {
  readonly runId: string;
  readonly name: string;
  readonly payload: Json;
}
export interface Signals {
  /** Durable: a signal sent before anyone waits is still delivered, exactly once. */
  send(signal: Signal): Durable<void>;
  /** Takes the oldest undelivered signal with this name, or `null`. Never blocks. */
  take(runId: string, name: string): Durable<Signal | null>;
}

// ── Side-effect ledger: reconcile, then act ──────────────────────────────────
export interface SideEffectRecord {
  readonly key: IdempotencyKey;
  readonly state: "pending" | "done";
  readonly result?: Json;
}
export interface SideEffects {
  /** Records intent; a known key returns its existing record, so the caller reconciles instead of acting twice. */
  begin(fence: FenceToken, key: IdempotencyKey): Durable<SideEffectRecord>;
  finish(fence: FenceToken, key: IdempotencyKey, result: Json): Durable<SideEffectRecord>;
}

/** One store implements all four ports, so fence checks and writes share a transaction. */
export interface Durability {
  readonly queue: WorkQueue;
  readonly journal: RunJournal;
  readonly signals: Signals;
  readonly sideEffects: SideEffects;
}
