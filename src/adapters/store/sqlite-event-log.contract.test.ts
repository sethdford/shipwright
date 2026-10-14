import { describe, test } from "bun:test";
import { join } from "node:path";
import { eventLogContract } from "../../testing/contracts/event-log-contract";
import { createTestEnv } from "../../testing/test-env";
import { SqliteEventLog } from "./sqlite-event-log";

describe("event log contract: bun:sqlite", () => {
  const factory = () => {
    const env = createTestEnv();
    const log = SqliteEventLog.open(join(env.stateDir, "shipwright.db"));
    const cleanup = () => {
      log.close();
      env.cleanup();
    };
    return { log, cleanup };
  };
  for (const c of eventLogContract) test(c.name, () => c.run(factory));
});
