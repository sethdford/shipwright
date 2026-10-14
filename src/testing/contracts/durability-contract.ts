import { expect } from "bun:test";
import { type Durability, idempotencyKey, type Lease } from "../../shared/kernel/durability";

/**
 * One contract case. Test files register cases themselves (`test(c.name, () => c.run(factory))`):
 * Bun drops `test()` calls made inside a helper module that a second test file also imports.
 */
export interface ContractCase<F> {
  readonly name: string;
  run(factory: F): Promise<void>;
}

/** Builds a fresh, empty store whose notion of time is `now` (epoch ms). */
export type DurabilityFactory = (now: () => number) => Durability | Promise<Durability>;

interface Ctx {
  readonly d: Durability;
  advance(ms: number): void;
  claimed(workerId: string): Promise<Lease>;
}
const item = { pool: "default", dedupeKey: "issue-1", payload: { issue: 1 } };
const entry = { runId: "r1", type: "stage.started", at: "t", data: {} };
const key = idempotencyKey("r1", "pr", "open");

async function fresh(factory: DurabilityFactory): Promise<Ctx> {
  let t = 1_000;
  const d = await factory(() => t);
  const advance = (ms: number) => {
    t += ms;
  };
  const claimed = async (workerId: string): Promise<Lease> => {
    const r = await d.queue.claim("default", workerId, 1_000);
    if (!r.ok || !r.value) throw new Error(`${workerId} expected a lease`);
    return r.value;
  };
  return { d, advance, claimed };
}

const queueCases: ContractCase<DurabilityFactory>[] = [
  {
    name: "of 10 concurrent claimers exactly one gets the item",
    run: async (factory) => {
      const { d } = await fresh(factory);
      await d.queue.enqueue(item);
      const claims = Array.from({ length: 10 }, (_, i) => d.queue.claim("default", `w${i}`, 1_000));
      const results = await Promise.all(claims);
      expect(results.filter((r) => r.ok && r.value !== null)).toHaveLength(1);
    },
  },
  {
    name: "a live lease blocks others; an expired lease is taken over with a higher epoch",
    run: async (factory) => {
      const ctx = await fresh(factory);
      await ctx.d.queue.enqueue(item);
      const first = await ctx.claimed("a");
      expect(await ctx.d.queue.claim("default", "b", 1_000)).toEqual({ ok: true, value: null });
      ctx.advance(1_001);
      expect((await ctx.claimed("b")).fence.epoch).toBeGreaterThan(first.fence.epoch);
    },
  },
  {
    name: "notBefore delays claiming; an unfinished dedupe key is rejected",
    run: async (factory) => {
      const ctx = await fresh(factory);
      await ctx.d.queue.enqueue({ ...item, notBefore: 1_500 });
      expect(await ctx.d.queue.claim("default", "a", 1_000)).toEqual({ ok: true, value: null });
      ctx.advance(500);
      await ctx.claimed("a");
      const dup = await ctx.d.queue.enqueue(item);
      expect(dup.ok ? "ok" : dup.error.kind).toBe("duplicate");
    },
  },
];

const fenceCases: ContractCase<DurabilityFactory>[] = [
  {
    name: "journal appends under a live fence are ordered by seq",
    run: async (factory) => {
      const ctx = await fresh(factory);
      await ctx.d.queue.enqueue(item);
      const { fence } = await ctx.claimed("a");
      await ctx.d.journal.append(fence, entry);
      await ctx.d.journal.append(fence, { ...entry, type: "stage.passed" });
      const read = await ctx.d.journal.read("r1", 1);
      expect(read.ok && read.value.map((e) => [e.seq, e.type])).toEqual([[2, "stage.passed"]]);
    },
  },
  {
    name: "after takeover every write with the old fence fails with stale_fence",
    run: async (factory) => {
      const ctx = await fresh(factory);
      await ctx.d.queue.enqueue(item);
      const old = (await ctx.claimed("a")).fence;
      ctx.advance(1_001);
      await ctx.claimed("b");
      const writes = [
        await ctx.d.journal.append(old, entry),
        await ctx.d.queue.heartbeat(old, 1_000),
        await ctx.d.queue.complete(old, "succeeded"),
        await ctx.d.sideEffects.begin(old, key),
        await ctx.d.sideEffects.finish(old, key, {}),
      ];
      expect(writes.map((w) => (w.ok ? "ok" : w.error.kind))).toEqual(Array(5).fill("stale_fence"));
    },
  },
];

const effectAndSignalCases: ContractCase<DurabilityFactory>[] = [
  {
    name: "a crashed holder's pending side effect is visible to the next holder",
    run: async (factory) => {
      const ctx = await fresh(factory);
      await ctx.d.queue.enqueue(item);
      await ctx.d.sideEffects.begin((await ctx.claimed("a")).fence, key);
      ctx.advance(1_001);
      const { fence } = await ctx.claimed("b");
      const again = await ctx.d.sideEffects.begin(fence, key);
      expect(again).toEqual({ ok: true, value: { key, state: "pending" } });
      const done = await ctx.d.sideEffects.finish(fence, key, { pr: 7 });
      expect(done.ok && done.value).toEqual({ key, state: "done", result: { pr: 7 } });
      expect(await ctx.d.sideEffects.begin(fence, key)).toEqual(done);
    },
  },
  {
    name: "a signal sent before anyone waits is delivered exactly once",
    run: async (factory) => {
      const { d } = await fresh(factory);
      const signal = { runId: "r1", name: "approve:plan", payload: { by: "maintainer" } };
      await d.signals.send(signal);
      expect(await d.signals.take("r1", "approve:pr")).toEqual({ ok: true, value: null });
      expect(await d.signals.take("r1", "approve:plan")).toEqual({ ok: true, value: signal });
      expect(await d.signals.take("r1", "approve:plan")).toEqual({ ok: true, value: null });
    },
  },
];

/** Every durability adapter (in-memory, SQLite, Postgres) must pass these cases unchanged. */
export const durabilityContract: readonly ContractCase<DurabilityFactory>[] = [
  ...queueCases,
  ...fenceCases,
  ...effectAndSignalCases,
];
