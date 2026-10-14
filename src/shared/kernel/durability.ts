import type { Result } from "./result";

// Durability contract (spec §6.1, ADR-0005). Types plus one pure helper; no adapters here.
// Adapters: SQLite (Wave 1, mode M1) and Postgres (Wave 2, modes M2/M3). Each must pass
// src/testing/contracts/durability-contract.ts unchanged.

/** Proof of the current lease on one work item. `epoch` grows on every successful claim. */
export interface FenceToken {
  readonly workId: string;
  readonly epoch: number;
}

/** Stable key for one external side effect, e.g. `run-42:pr:open`. */
export type IdempotencyKey = string & { readonly __brand: "IdempotencyKey" };
export const idempotencyKey = (...parts: readonly string[]): IdempotencyKey =>
  parts.join(":") as IdempotencyKey;

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
  /** Enqueueing while an unfinished item has the same key fails with `duplicate`. */
  readonly dedupeKey: string;
  readonly payload: Json;
  /** Epoch milliseconds before which the item is not claimable. */
  readonly notBefore?: number;
}
export interface Lease {
  readonly fence: FenceToken;
  readonly workerId: string;
  readonly expiresAt: number;
  readonly payload: Json;
}
export interface WorkQueue {
  enqueue(item: NewWorkItem): Durable<string>;
  /** Oldest ready, unleased (or lease-expired) item in `pool`; `null` when none. */
  claim(pool: string, workerId: string, leaseMs: number): Durable<Lease | null>;
  heartbeat(fence: FenceToken, leaseMs: number): Durable<Lease>;
  complete(fence: FenceToken, outcome: "succeeded" | "failed"): Durable<void>;
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
  /** Fails with `stale_fence` unless `fence` is the live lease. */
  append(fence: FenceToken, entry: Omit<JournalEntry, "seq">): Durable<JournalEntry>;
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
