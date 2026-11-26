import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import type { Bm25Index } from "../domain/bm25";
import { buildGraph, type RepoGraph } from "../domain/graph";
import { type Entity, entityIndex } from "../domain/localize";
import {
  buildSemantic,
  type SemanticHit,
  type SemanticIndex,
  searchSemantic,
  semanticDocs,
} from "../domain/lsa";
import type { RepoModelPorts } from "../ports";
import { type OwnerRule, parseCodeowners } from "./owners";
import { type RefreshStats, refreshModel } from "./refresh";

export interface Snapshot {
  readonly graph: RepoGraph;
  readonly index: Bm25Index<Entity>;
  /** Semantic neighbours of a text (LSA over the files), built on first use; [] when the session has it off. */
  readonly semantic: (text: string, limit: number) => readonly SemanticHit[];
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
    /** The semantic channel (ADR-0016); off for the lexical-only ablation arm. */
    readonly semanticOn = true,
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
      semantic: this.semanticOn ? lazySemantic(graph) : () => [],
      owners: parseCodeowners(model.codeowners),
      stats,
    };
    return ok(this.snapshot);
  }

  read(path: string): Promise<Result<string, AdapterError>> {
    return this.ports.source.read(this.root, path);
  }
}

/** The LSA index costs about half a second on a thousand files, so it is built only when a query needs it. */
function lazySemantic(graph: RepoGraph): Snapshot["semantic"] {
  let index: SemanticIndex | undefined;
  return (text, limit) => {
    index ??= buildSemantic(semanticDocs(graph.model.files));
    return searchSemantic(index, text, limit);
  };
}
