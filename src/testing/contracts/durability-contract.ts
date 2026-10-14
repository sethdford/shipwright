import { expect } from "bun:test";
import {
  type ContractCase,
  type DurabilityFactory,
  entry,
  fresh,
  item,
  key,
  kindOf,
  nth,
} from "./durability-fixture";

export type { ContractCase, DurabilityFactory } from "./durability-fixture";

// Invariants pinned here (every adapter must hold all of them):
// - claims are exclusive: of N concurrent claimers exactly one gets an item;
// - an expired lease can be re-claimed, and each claim raises the fence epoch;
// - heartbeat extends the live lease, so other claimers stay blocked;
// - a holder whose lease expired is stale even if nobody re-claimed the item;
// - every write with a non-live fence (append, heartbeat, complete, begin, finish) fails stale_fence;
// - complete is terminal for both outcomes: the item is never claimed again, the outcome is
//   readable, and its dedupe key and run are free for a new item (retries are new items);
// - notBefore delays claiming (the timer wake); an unfinished dedupe key or run rejects enqueue
//   with `duplicate`, so a run has at most one live lease;
// - claim's maxActive caps live leases per pool, even under concurrent claimers; expired leases
//   and other pools do not count;
// - append writes to the fence's own run only: a live lease cannot write another run's journal;
// - journal seq is per run and ordered; read(afterSeq) returns only later entries;
// - side effects are keyed: a pending or done record is returned, never re-begun;
// - finishing a never-begun side effect is `not_found`;
// - a signal sent before anyone waits is delivered exactly once.

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
    name: "notBefore delays claiming; an unfinished dedupe key or run is rejected",
    run: async (factory) => {
      const ctx = await fresh(factory);
      await ctx.d.queue.enqueue({ ...item, notBefore: 1_500 });
      expect(await ctx.d.queue.claim("default", "a", 1_000)).toEqual({ ok: true, value: null });
      ctx.advance(500);
      expect((await ctx.claimed("a")).runId).toBe("r1");
      expect(kindOf(await ctx.d.queue.enqueue(item))).toBe("duplicate");
      expect(kindOf(await ctx.d.queue.enqueue({ ...item, dedupeKey: "other" }))).toBe("duplicate");
    },
  },
  {
    name: "maxActive caps live leases per pool, even under concurrent claimers",
    run: async (factory) => {
      const ctx = await fresh(factory);
      for (const n of [1, 2, 3, 4]) await ctx.d.queue.enqueue(nth(n));
      await ctx.d.queue.enqueue(nth(5, "other"));
      const limits = { maxActive: 2 };
      const claims = Array.from({ length: 6 }, (_, i) =>
        ctx.d.queue.claim("default", `w${i}`, 1_000, limits),
      );
      const leases = (await Promise.all(claims)).filter((r) => r.ok && r.value !== null);
      expect(leases).toHaveLength(2);
      await ctx.claimed("x", "other", { maxActive: 1 });
      const first = leases[0];
      if (!first?.ok || !first.value) throw new Error("expected a lease");
      await ctx.d.queue.complete(first.value.fence, "succeeded");
      await ctx.claimed("y", "default", limits);
      ctx.advance(1_001);
      await ctx.claimed("z", "default", limits);
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
    name: "a live lease appends only to its own run, never to a run it does not hold",
    run: async (factory) => {
      const ctx = await fresh(factory);
      await ctx.d.queue.enqueue(nth(1));
      await ctx.d.queue.enqueue(nth(2));
      await ctx.claimed("a");
      const b = await ctx.claimed("b");
      const smuggled = { ...entry, runId: "r1" };
      const wrote = await ctx.d.journal.append(b.fence, smuggled);
      expect(wrote.ok && [wrote.value.runId, wrote.value.seq]).toEqual(["r2", 1]);
      expect(await ctx.d.journal.read("r1")).toEqual({ ok: true, value: [] });
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
      expect(writes.map(kindOf)).toEqual(Array(5).fill("stale_fence"));
    },
  },
];

const leaseCases: ContractCase<DurabilityFactory>[] = [
  {
    name: "heartbeat extends the lease, so a claimer inside the new window is blocked",
    run: async (factory) => {
      const ctx = await fresh(factory);
      await ctx.d.queue.enqueue(item);
      const { fence } = await ctx.claimed("a");
      ctx.advance(800);
      expect((await ctx.d.queue.heartbeat(fence, 1_000)).ok).toBe(true);
      ctx.advance(500);
      expect(await ctx.d.queue.claim("default", "b", 1_000)).toEqual({ ok: true, value: null });
      expect((await ctx.d.journal.append(fence, entry)).ok).toBe(true);
    },
  },
  {
    name: "an expired holder is stale even when nobody has re-claimed the item",
    run: async (factory) => {
      const ctx = await fresh(factory);
      await ctx.d.queue.enqueue(item);
      const { fence } = await ctx.claimed("a");
      ctx.advance(1_000);
      const writes = [
        await ctx.d.journal.append(fence, entry),
        await ctx.d.queue.heartbeat(fence, 1_000),
        await ctx.d.queue.complete(fence, "succeeded"),
        await ctx.d.sideEffects.begin(fence, key),
      ];
      expect(writes.map(kindOf)).toEqual(Array(4).fill("stale_fence"));
    },
  },
  {
    name: "succeeded and failed are both terminal, readable, and free the dedupe key and run",
    run: async (factory) => {
      const ctx = await fresh(factory);
      for (const outcome of ["succeeded", "failed"] as const) {
        const id = await ctx.d.queue.enqueue(item);
        if (!id.ok) throw new Error("enqueue failed");
        const { fence } = await ctx.claimed("a");
        expect(await ctx.d.queue.outcome(id.value)).toEqual({ ok: true, value: null });
        expect(await ctx.d.queue.complete(fence, outcome)).toEqual({ ok: true, value: undefined });
        expect(await ctx.d.queue.outcome(id.value)).toEqual({ ok: true, value: outcome });
        expect(kindOf(await ctx.d.queue.complete(fence, outcome))).toBe("stale_fence");
        ctx.advance(1_001);
        expect(await ctx.d.queue.claim("default", "b", 1_000)).toEqual({ ok: true, value: null });
      }
      expect(kindOf(await ctx.d.queue.outcome("missing"))).toBe("not_found");
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
    name: "finishing a side effect that was never begun is not_found",
    run: async (factory) => {
      const ctx = await fresh(factory);
      await ctx.d.queue.enqueue(item);
      const { fence } = await ctx.claimed("a");
      expect(kindOf(await ctx.d.sideEffects.finish(fence, key, { pr: 7 }))).toBe("not_found");
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
  ...leaseCases,
  ...effectAndSignalCases,
];
