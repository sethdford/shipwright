import type {
  ClaimLimits,
  Durability,
  DurabilityError,
  FenceToken,
  IdempotencyKey,
  JournalEntry,
  Lease,
  NewWorkItem,
  RunJournal,
  SideEffectRecord,
  SideEffects,
  Signal,
  Signals,
  WorkOutcome,
  WorkQueue,
} from "../shared/kernel/durability";
import { err, ok, type Result } from "../shared/kernel/result";

type R<T> = Promise<Result<T, DurabilityError>>;
interface Item extends NewWorkItem {
  readonly id: string;
  epoch: number;
  workerId: string;
  expiresAt: number;
  outcome: WorkOutcome | null;
}
const fail = (kind: DurabilityError["kind"], message: string) => err({ kind, message });

class Store {
  readonly items: Item[] = [];
  readonly entries: JournalEntry[] = [];
  readonly signals: Signal[] = [];
  readonly effects = new Map<IdempotencyKey, SideEffectRecord>();
  constructor(readonly now: () => number) {}

  /** The single fence check every fenced write goes through. */
  live(fence: FenceToken): Result<Item, DurabilityError> {
    const item = this.items.find((i) => i.id === fence.workId);
    if (!item) return fail("not_found", `no work item ${fence.workId}`);
    if (item.outcome || item.epoch !== fence.epoch || item.expiresAt <= this.now()) {
      return fail("stale_fence", `epoch ${fence.epoch} is not the live lease on ${fence.workId}`);
    }
    return ok(item);
  }
}

const leaseOf = (item: Item): Lease => ({
  fence: { workId: item.id, epoch: item.epoch },
  runId: item.runId,
  workerId: item.workerId,
  expiresAt: item.expiresAt,
  payload: item.payload,
});

class MemoryQueue implements WorkQueue {
  constructor(private readonly s: Store) {}
  async enqueue(item: NewWorkItem): R<string> {
    const clash = this.s.items.find(
      (i) => !i.outcome && (i.dedupeKey === item.dedupeKey || i.runId === item.runId),
    );
    if (clash) return fail("duplicate", `unfinished item ${clash.id} has this dedupe key or run`);
    const id = `w${this.s.items.length + 1}`;
    this.s.items.push({ ...item, id, epoch: 0, workerId: "", expiresAt: 0, outcome: null });
    return ok(id);
  }
  async claim(
    pool: string,
    workerId: string,
    leaseMs: number,
    limits?: ClaimLimits,
  ): R<Lease | null> {
    const t = this.s.now();
    const open = this.s.items.filter((i) => i.pool === pool && !i.outcome);
    const active = open.filter((i) => i.expiresAt > t).length;
    if (limits?.maxActive !== undefined && active >= limits.maxActive) return ok(null);
    const item = open.find((i) => (i.notBefore ?? 0) <= t && i.expiresAt <= t);
    if (!item) return ok(null);
    Object.assign(item, { epoch: item.epoch + 1, workerId, expiresAt: t + leaseMs });
    return ok(leaseOf(item));
  }
  async heartbeat(fence: FenceToken, leaseMs: number): R<Lease> {
    const item = this.s.live(fence);
    if (!item.ok) return item;
    item.value.expiresAt = this.s.now() + leaseMs;
    return ok(leaseOf(item.value));
  }
  async complete(fence: FenceToken, outcome: WorkOutcome): R<void> {
    const item = this.s.live(fence);
    if (!item.ok) return item;
    item.value.outcome = outcome;
    return ok(undefined);
  }
  async outcome(workId: string): R<WorkOutcome | null> {
    const item = this.s.items.find((i) => i.id === workId);
    return item ? ok(item.outcome) : fail("not_found", `no work item ${workId}`);
  }
}

class MemoryJournal implements RunJournal {
  constructor(private readonly s: Store) {}
  async append(fence: FenceToken, entry: Omit<JournalEntry, "seq" | "runId">): R<JournalEntry> {
    const item = this.s.live(fence);
    if (!item.ok) return item;
    const { runId } = item.value;
    const seq = this.s.entries.filter((e) => e.runId === runId).length + 1;
    // Built field by field: the run is always the lease's, whatever else the caller's object carries.
    const stored: JournalEntry = { type: entry.type, at: entry.at, data: entry.data, runId, seq };
    this.s.entries.push(stored);
    return ok(stored);
  }
  async read(runId: string, afterSeq = 0): R<readonly JournalEntry[]> {
    return ok(this.s.entries.filter((e) => e.runId === runId && e.seq > afterSeq));
  }
}

class MemorySignals implements Signals {
  constructor(private readonly s: Store) {}
  async send(signal: Signal): R<void> {
    this.s.signals.push(signal);
    return ok(undefined);
  }
  async take(runId: string, name: string): R<Signal | null> {
    const index = this.s.signals.findIndex((x) => x.runId === runId && x.name === name);
    return ok(index < 0 ? null : (this.s.signals.splice(index, 1)[0] ?? null));
  }
}

class MemorySideEffects implements SideEffects {
  constructor(private readonly s: Store) {}
  async begin(fence: FenceToken, key: IdempotencyKey): R<SideEffectRecord> {
    const item = this.s.live(fence);
    if (!item.ok) return item;
    const record = this.s.effects.get(key) ?? { key, state: "pending" };
    this.s.effects.set(key, record);
    return ok(record);
  }
  async finish(
    fence: FenceToken,
    key: IdempotencyKey,
    result: Record<string, unknown>,
  ): R<SideEffectRecord> {
    const item = this.s.live(fence);
    if (!item.ok) return item;
    if (!this.s.effects.has(key)) return fail("not_found", `side effect ${key} was never begun`);
    const record: SideEffectRecord = { key, state: "done", result };
    this.s.effects.set(key, record);
    return ok(record);
  }
}

/** Reference implementation of the durability ports, for application tests and the contract suite. */
export function createInMemoryDurability(now: () => number): Durability {
  const store = new Store(now);
  return {
    queue: new MemoryQueue(store),
    journal: new MemoryJournal(store),
    signals: new MemorySignals(store),
    sideEffects: new MemorySideEffects(store),
  };
}
