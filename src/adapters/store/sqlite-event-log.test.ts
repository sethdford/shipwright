import { Database } from "bun:sqlite";
import { afterEach, expect, test } from "bun:test";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { SCHEMA_VERSION, SqliteEventLog } from "./sqlite-event-log";

let env: TestEnv | undefined;
afterEach(() => env?.cleanup());

function userVersion(path: string): number {
  const db = new Database(path);
  try {
    return db.query<{ user_version: number }, []>("PRAGMA user_version").get()?.user_version ?? -1;
  } finally {
    db.close();
  }
}

test("appends and lists events per run, oldest first", () => {
  env = createTestEnv();
  using log = SqliteEventLog.open(join(env.stateDir, "shipwright.db"));
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
  expect(log.list("unknown")).toEqual([]);
});

test("reopening an existing database keeps data and does not re-run migrations", () => {
  env = createTestEnv();
  const path = join(env.stateDir, "shipwright.db");
  {
    using first = SqliteEventLog.open(path);
    first.append({ runId: "r1", type: "x", at: "t", data: {} });
  }
  {
    using second = SqliteEventLog.open(path);
    expect(second.list("r1")).toHaveLength(1);
  }
  expect(userVersion(path)).toBe(SCHEMA_VERSION);
  expect(SCHEMA_VERSION).toBe(1);
});

test("refuses a database from a newer binary", () => {
  env = createTestEnv();
  const path = join(env.stateDir, "shipwright.db");
  const raw = new Database(path, { create: true });
  raw.run("PRAGMA user_version = 99");
  raw.close();
  expect(() => SqliteEventLog.open(path)).toThrow(/newer than this binary/);
});

test("a failed migration rolls back everything including user_version", () => {
  env = createTestEnv();
  const path = join(env.stateDir, "shipwright.db");
  const migrations = ["CREATE TABLE events (id INTEGER PRIMARY KEY)", "THIS IS NOT SQL"];
  expect(() => SqliteEventLog.open(path, migrations)).toThrow();
  expect(userVersion(path)).toBe(0);
  const raw = new Database(path);
  const tables = raw.query("SELECT name FROM sqlite_master WHERE name = 'events'").all();
  raw.close();
  expect(tables).toEqual([]);
});

test("rejects non-object data at the database level", () => {
  env = createTestEnv();
  const path = join(env.stateDir, "shipwright.db");
  const log = SqliteEventLog.open(path);
  log.close();
  const raw = new Database(path);
  expect(() =>
    raw.run("INSERT INTO events (run_id, type, at, data) VALUES ('r','t','a','[1]')"),
  ).toThrow();
  raw.close();
});
