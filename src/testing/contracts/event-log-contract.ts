import { expect } from "bun:test";
import type { EventLog } from "../../shared/kernel/ports";
import type { ContractCase } from "./durability-contract";

/** Opens a fresh, empty log and a cleanup for it. */
export type EventLogFactory = () => { readonly log: EventLog; cleanup(): void };

async function withLog(factory: EventLogFactory, body: (log: EventLog) => void): Promise<void> {
  const { log, cleanup } = factory();
  try {
    body(log);
  } finally {
    cleanup();
  }
}

/** Every EventLog (in-memory fake, bun:sqlite store) must pass these cases unchanged. */
export const eventLogContract: readonly ContractCase<EventLogFactory>[] = [
  {
    name: "lists one run's events oldest first, with data intact",
    run: (factory) =>
      withLog(factory, (log) => {
        log.append({ runId: "r1", type: "a", at: "t1", data: { n: 1 } });
        log.append({ runId: "r2", type: "b", at: "t2", data: {} });
        log.append({ runId: "r1", type: "c", at: "t3", data: { n: 3 } });
        expect(log.list("r1").map((e) => [e.type, e.data])).toEqual([
          ["a", { n: 1 }],
          ["c", { n: 3 }],
        ]);
      }),
  },
  {
    name: "an unknown run has no events",
    run: (factory) => withLog(factory, (log) => expect(log.list("missing")).toEqual([])),
  },
];
