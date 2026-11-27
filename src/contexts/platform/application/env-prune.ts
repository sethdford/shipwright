import type { AdapterError } from "../../../shared/kernel/ports";
import type { Result } from "../../../shared/kernel/result";
import { ok } from "../../../shared/kernel/result";
import type { CacheEntry, EnvPorts } from "../ports";

export interface PrunePolicy {
  /** Entries to keep per repository, most recently used first. */
  readonly keep: number;
  /** Also remove entries unused for longer than this, even within `keep`. */
  readonly maxAgeDays: number;
  readonly dryRun: boolean;
}

/** Which entries a policy removes (pure, so the policy is testable without a filesystem). */
export function pickStale(
  entries: readonly CacheEntry[],
  p: PrunePolicy,
  nowMs: number,
): CacheEntry[] {
  const byUse = [...entries].sort((a, b) => Date.parse(b.usedAt) - Date.parse(a.usedAt));
  const cutoff = nowMs - p.maxAgeDays * 86_400_000;
  return byUse.filter((e, i) => i >= p.keep || Date.parse(e.usedAt) < cutoff);
}

export async function pruneCache(
  ports: EnvPorts,
  repoId: string,
  p: PrunePolicy,
): Promise<Result<CacheEntry[], AdapterError>> {
  const entries = await ports.cache.list(repoId);
  if (!entries.ok) return entries;
  const stale = pickStale(entries.value, p, ports.now());
  if (!p.dryRun) {
    for (const e of stale) {
      const r = await ports.cache.remove(e.repoId, e.key);
      if (!r.ok) return r;
    }
  }
  return ok(stale);
}
