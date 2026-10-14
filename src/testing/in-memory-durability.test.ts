import { describe, test } from "bun:test";
import { durabilityContract } from "./contracts/durability-contract";
import { eventLogContract } from "./contracts/event-log-contract";
import { createInMemoryDurability } from "./in-memory-durability";
import { InMemoryEventLog } from "./in-memory-event-log";

describe("durability contract: in-memory", () => {
  for (const c of durabilityContract) test(c.name, () => c.run(createInMemoryDurability));
});

describe("event log contract: in-memory", () => {
  const factory = () => ({ log: new InMemoryEventLog(), cleanup: () => {} });
  for (const c of eventLogContract) test(c.name, () => c.run(factory));
});
