import {
  type ClaimLimits,
  type Durability,
  idempotencyKey,
  type Lease,
} from "../../shared/kernel/durability";

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

export interface Ctx {
  readonly d: Durability;
  advance(ms: number): void;
  claimed(workerId: string, pool?: string, limits?: ClaimLimits): Promise<Lease>;
}

export const item = { pool: "default", runId: "r1", dedupeKey: "issue-1", payload: { issue: 1 } };
/** The n-th distinct item (own run and dedupe key) in `pool`. */
export const nth = (n: number, pool = "default") => ({
  pool,
  runId: `r${n}`,
  dedupeKey: `issue-${n}`,
  payload: { issue: n },
});
export const entry = { type: "stage.started", at: "t", data: {} };
export const key = idempotencyKey("r1", "pr", "open");

export async function fresh(factory: DurabilityFactory): Promise<Ctx> {
  let t = 1_000;
  const d = await factory(() => t);
  const advance = (ms: number) => {
    t += ms;
  };
  const claimed = async (workerId: string, pool = "default", limits?: ClaimLimits) => {
    const r = await d.queue.claim(pool, workerId, 1_000, limits);
    if (!r.ok || !r.value) throw new Error(`${workerId} expected a lease`);
    return r.value;
  };
  return { d, advance, claimed };
}

/** `"ok"` or the error kind, for compact assertions over several writes. */
export const kindOf = (r: { ok: true } | { ok: false; error: { kind: string } }): string =>
  r.ok ? "ok" : r.error.kind;
