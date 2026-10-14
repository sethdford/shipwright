import type { EventLog, EventRecord } from "../shared/kernel/ports";

/** In-memory EventLog for application tests; held to the same contract as SqliteEventLog. */
export class InMemoryEventLog implements EventLog {
  private readonly events: EventRecord[] = [];
  append(event: EventRecord): void {
    this.events.push(event);
  }
  list(runId: string): readonly EventRecord[] {
    return this.events.filter((e) => e.runId === runId);
  }
}
