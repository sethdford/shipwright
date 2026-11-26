import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import { localize } from "../domain/localize";
import { renderBrief } from "../domain/render";
import { testsFor } from "../domain/tests-map";
import { ownersOf } from "./owners";
import type { RefreshStats } from "./refresh";
import type { RepoSession } from "./session";

export interface Brief {
  readonly text: string;
  /** The files the brief names, best first (for the run's event, so a paired comparison can audit it). */
  readonly files: readonly string[];
  readonly stats: RefreshStats;
}

/** The repository-model section of an agent prompt for a task (ADR-0012). */
export async function buildBrief(
  session: RepoSession,
  task: string,
  toolsAvailable: boolean,
): Promise<Result<Brief, AdapterError>> {
  const snap = await session.current();
  if (!snap.ok) return snap;
  const { graph, index, owners, stats } = snap.value;
  const located = localize(graph, index, task, 12);
  const src = located.filter((f) => !f.test).slice(0, 8);
  const text = renderBrief({
    located,
    tests: new Map(src.map((f) => [f.path, testsFor(graph, f.path)] as const)),
    owners: new Map(src.map((f) => [f.path, ownersOf(owners, f.path)] as const)),
    toolsAvailable,
    stats: {
      files: graph.model.files.length,
      symbols: graph.model.files.reduce((a, f) => a + f.symbols.length, 0),
    },
  });
  return ok({ text, files: src.map((f) => f.path), stats });
}
