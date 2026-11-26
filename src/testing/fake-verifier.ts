import type { FileChange, PullRecord, StoredVerifier, VerifierPorts } from "../contexts/quality";
import type { AgentRunner, DecideRequest } from "../shared/kernel/ports";
import { err, ok } from "../shared/kernel/result";

const USAGE = { costUsd: 0.04, inputTokens: 1, outputTokens: 1, durationMs: 1 };

/** An agent whose `decide` returns `value` (validated by the request's schema) or fails. */
export function fakeCritic(
  value: unknown | null,
): AgentRunner & { requests: DecideRequest<unknown>[] } {
  const requests: DecideRequest<unknown>[] = [];
  return {
    requests,
    async decide<T>(req: DecideRequest<T>) {
      requests.push(req as DecideRequest<unknown>);
      if (value === null) return err({ kind: "timeout", message: "slow", usage: USAGE });
      return ok({ value: req.schema.parse(value), usage: USAGE });
    },
    async runTask() {
      throw new Error("the verifier never runs tasks");
    },
  } as AgentRunner & { requests: DecideRequest<unknown>[] };
}

export interface FakeVerifierOptions {
  readonly now?: number;
  readonly pulls?: readonly PullRecord[];
  readonly prFiles?: Readonly<Record<number, readonly FileChange[]>>;
  readonly local?: { readonly files: readonly FileChange[]; readonly patch: string };
  readonly stored?: StoredVerifier | null;
  readonly agent?: AgentRunner;
}

/** In-memory verifier ports; `saved` collects what training wrote. */
export function fakeVerifierPorts(o: FakeVerifierOptions = {}): VerifierPorts & {
  saved: StoredVerifier[];
} {
  const saved: StoredVerifier[] = [];
  let stored = o.stored ?? null;
  return {
    saved,
    now: () => o.now ?? Date.UTC(2026, 10, 26),
    pulls: {
      closedSince: async () => ok({ pulls: [...(o.pulls ?? [])], truncated: false }),
      commits: async () => ok([]),
    },
    files: {
      files: async (pr) => {
        const f = o.prFiles?.[pr];
        return f ? ok(f) : err({ kind: "not_found", message: `no PR ${pr}` });
      },
    },
    change: { diff: async () => ok(o.local ?? { files: [], patch: "" }) },
    store: {
      load: async () => ok(stored),
      save: async (v) => {
        saved.push(v);
        stored = v;
        return ok(undefined);
      },
    },
    agent: o.agent ?? fakeCritic(null),
  };
}
