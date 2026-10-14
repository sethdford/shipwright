import { afterEach, expect, test } from "bun:test";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { SqliteEventLog } from "./sqlite-event-log";

let env: TestEnv | undefined;
afterEach(() => env?.cleanup());

test("appends and lists events per run, oldest first", () => {
  env = createTestEnv();
  const log = SqliteEventLog.open(join(env.stateDir, "shipwright.db"));
  log.append({
    runId: "r1",
    type: "stage.started",
    at: "2026-10-13T00:00:00Z",
    data: { stage: "build" },
  });
  log.append({ runId: "r2", type: "stage.started", at: "2026-10-13T00:00:01Z", data: {} });
  log.append({
    runId: "r1",
    type: "stage.passed",
    at: "2026-10-13T00:00:02Z",
    data: { stage: "build" },
  });

  expect(log.list("r1").map((e) => e.type)).toEqual(["stage.started", "stage.passed"]);
  expect(log.list("r1")[0]?.data).toEqual({ stage: "build" });
});

test("reopening an existing database keeps data and does not re-run migrations", () => {
  env = createTestEnv();
  const path = join(env.stateDir, "shipwright.db");
  SqliteEventLog.open(path).append({ runId: "r1", type: "x", at: "t", data: {} });
  expect(SqliteEventLog.open(path).list("r1")).toHaveLength(1);
});
