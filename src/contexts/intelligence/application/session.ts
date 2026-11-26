import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import type { Bm25Index } from "../domain/bm25";
import { buildGraph, type RepoGraph } from "../domain/graph";
import { type Entity, entityIndex } from "../domain/localize";
import type { RepoModelPorts } from "../ports";
import { type OwnerRule, parseCodeowners } from "./owners";
import { type RefreshStats, refreshModel } from "./refresh";

export interface Snapshot {
  readonly graph: RepoGraph;
  readonly index: Bm25Index<Entity>;
  readonly owners: readonly OwnerRule[];
  readonly stats: RefreshStats;
}

/**
 * One repository's model held in memory for a series of queries (an MCP server's lifetime, or one command).
 * Every `current()` refreshes incrementally first, so answers include the agent's own uncommitted edits; the
 * graph and search index are rebuilt only when a file actually changed.
 */
export class RepoSession {
  private snapshot: Snapshot | undefined;

  constructor(
    readonly ports: RepoModelPorts,
    readonly root: string,
  ) {}

  async current(): Promise<Result<Snapshot, AdapterError>> {
    const r = await refreshModel(this.ports, this.root);
    if (!r.ok) return r;
    const { model, stats, changed } = r.value;
    if (
      this.snapshot &&
      !changed &&
      this.snapshot.graph.model.files.length === model.files.length
    ) {
      this.snapshot = { ...this.snapshot, stats };
      return ok(this.snapshot);
    }
    const graph = buildGraph(model);
    this.snapshot = {
      graph,
      index: entityIndex(graph),
      owners: parseCodeowners(model.codeowners),
      stats,
    };
    return ok(this.snapshot);
  }

  read(path: string): Promise<Result<string, AdapterError>> {
    return this.ports.source.read(this.root, path);
  }
}
