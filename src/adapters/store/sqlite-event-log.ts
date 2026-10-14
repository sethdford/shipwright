import { Database } from "bun:sqlite";
import type { EventLog, EventRecord } from "../../shared/kernel/ports";

const MIGRATIONS: readonly string[] = [
  `CREATE TABLE events (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     run_id TEXT NOT NULL,
     type TEXT NOT NULL,
     at TEXT NOT NULL,
     data TEXT NOT NULL
   );
   CREATE INDEX events_run ON events(run_id, id);`,
];

function migrate(db: Database): void {
  db.run("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)");
  const row = db.query<{ version: number }, []>("SELECT version FROM schema_version").get();
  const current = row?.version ?? 0;
  if (!row) db.run("INSERT INTO schema_version (version) VALUES (0)");
  for (let v = current; v < MIGRATIONS.length; v++) {
    db.transaction(() => {
      db.run(MIGRATIONS[v] as string);
      db.run("UPDATE schema_version SET version = ?", [v + 1]);
    })();
  }
}

export class SqliteEventLog implements EventLog {
  private constructor(private readonly db: Database) {}

  static open(path: string): SqliteEventLog {
    const db = new Database(path, { create: true });
    db.run("PRAGMA journal_mode = WAL");
    migrate(db);
    return new SqliteEventLog(db);
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
