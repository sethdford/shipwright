import { Database } from "bun:sqlite";
import type { EventLog, EventRecord } from "../../shared/kernel/ports";

const MIGRATIONS: readonly string[] = [
  `CREATE TABLE events (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     run_id TEXT NOT NULL,
     type TEXT NOT NULL,
     at TEXT NOT NULL,
     data TEXT NOT NULL CHECK (json_valid(data) AND json_type(data) = 'object')
   );
   CREATE INDEX events_run ON events(run_id, id);`,
];

export const SCHEMA_VERSION = MIGRATIONS.length;

function migrate(db: Database, migrations: readonly string[]): void {
  db.transaction(() => {
    const row = db.query<{ user_version: number }, []>("PRAGMA user_version").get();
    const current = row?.user_version ?? 0;
    if (current > migrations.length) {
      throw new Error(`db schema v${current} is newer than this binary (v${migrations.length})`);
    }
    for (let v = current; v < migrations.length; v++) db.run(migrations[v] as string);
    // PRAGMA does not accept bound parameters; the value is a trusted integer.
    db.run(`PRAGMA user_version = ${migrations.length}`);
  }).immediate();
}

export class SqliteEventLog implements EventLog {
  private constructor(private readonly db: Database) {}

  /** `migrations` is an internal seam for tests; production callers use the default. */
  static open(path: string, migrations: readonly string[] = MIGRATIONS): SqliteEventLog {
    const db = new Database(path, { create: true });
    try {
      db.run("PRAGMA busy_timeout = 5000");
      db.run("PRAGMA journal_mode = WAL");
      db.run("PRAGMA synchronous = NORMAL");
      migrate(db, migrations);
    } catch (err) {
      db.close();
      throw err;
    }
    return new SqliteEventLog(db);
  }

  close(): void {
    this.db.close();
  }

  [Symbol.dispose](): void {
    this.close();
  }

  append(event: EventRecord): void {
    this.db.run("INSERT INTO events (run_id, type, at, data) VALUES (?, ?, ?, ?)", [
      event.runId,
      event.type,
      event.at,
      JSON.stringify(event.data),
    ]);
  }

  list(runId: string): EventRecord[] {
    return this.db
      .query<{ run_id: string; type: string; at: string; data: string }, [string]>(
        "SELECT run_id, type, at, data FROM events WHERE run_id = ? ORDER BY id",
      )
      .all(runId)
      .map((r) => ({ runId: r.run_id, type: r.type, at: r.at, data: JSON.parse(r.data) }));
  }
}
