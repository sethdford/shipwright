import { resolveImport } from "./imports";
import type { FileEntry, RepoModel, SymbolDef } from "./model";

export interface SymbolRef {
  readonly path: string;
  readonly symbol: SymbolDef;
}

/**
 * The queryable graph over a model: who defines a name, what a file imports and who imports it, and which
 * files refer to names another file defines (the reference edges a repo map ranks by, as in Aider's map).
 */
export interface RepoGraph {
  readonly model: RepoModel;
  readonly byPath: ReadonlyMap<string, FileEntry>;
  readonly defs: ReadonlyMap<string, readonly SymbolRef[]>;
  readonly imports: ReadonlyMap<string, readonly string[]>;
  readonly importers: ReadonlyMap<string, readonly string[]>;
  /** path → (other path → weight): this file refers to names the other defines. */
  readonly refEdges: ReadonlyMap<string, ReadonlyMap<string, number>>;
  /** name → paths that refer to it. */
  readonly referrers: ReadonlyMap<string, readonly string[]>;
}

/** Names this common carry little signal (they are defined in many files); they are skipped as edges. */
const MAX_DEFINERS = 12;

function push<K, V>(map: Map<K, V[]>, key: K, value: V): void {
  const list = map.get(key);
  if (list) list.push(value);
  else map.set(key, [value]);
}

function indexDefs(files: readonly FileEntry[]): Map<string, SymbolRef[]> {
  const defs = new Map<string, SymbolRef[]>();
  for (const f of files) for (const s of f.symbols) push(defs, s.name, { path: f.path, symbol: s });
  return defs;
}

function indexImports(files: readonly FileEntry[], paths: ReadonlySet<string>) {
  const imports = new Map<string, string[]>();
  const importers = new Map<string, string[]>();
  for (const f of files) {
    const targets = new Set<string>();
    for (const spec of f.imports) {
      const to = resolveImport(f.lang, f.path, spec, paths);
      if (to !== undefined && to !== f.path) targets.add(to);
    }
    const list = [...targets].sort();
    imports.set(f.path, list);
    for (const to of list) push(importers, to, f.path);
  }
  return { imports, importers };
}

/** Aider's weighting: long, specific names count more; private and widely defined names count less. */
export function nameWeight(name: string, definers: number): number {
  let w = 1;
  if (name.length >= 8 && (/[a-z][A-Z]/.test(name) || name.includes("_"))) w *= 4;
  if (name.startsWith("_")) w *= 0.3;
  if (definers > 3) w *= 0.3;
  return w;
}

/** Names connect files of one language family only: a bash function and a TS variable sharing a name do not. */
function family(lang: string): string {
  return lang === "js" ? "ts" : lang;
}

function indexRefs(files: readonly FileEntry[], defs: ReadonlyMap<string, readonly SymbolRef[]>) {
  const langOf = new Map(files.map((f) => [f.path, family(f.lang)] as const));
  const refEdges = new Map<string, Map<string, number>>();
  const referrers = new Map<string, string[]>();
  for (const f of files) {
    const edges = new Map<string, number>();
    for (const name of f.refs) {
      const all = defs.get(name);
      if (!all || all.length > MAX_DEFINERS) continue;
      const targets = all.filter((t) => langOf.get(t.path) === family(f.lang));
      if (targets.length === 0) continue;
      push(referrers, name, f.path);
      const definers = new Set(targets.map((t) => t.path));
      const w = nameWeight(name, definers.size) / definers.size;
      for (const to of definers) if (to !== f.path) edges.set(to, (edges.get(to) ?? 0) + w);
    }
    refEdges.set(f.path, edges);
  }
  return { refEdges, referrers };
}

export function buildGraph(model: RepoModel): RepoGraph {
  const byPath = new Map(model.files.map((f) => [f.path, f] as const));
  const defs = indexDefs(model.files);
  const { imports, importers } = indexImports(model.files, new Set(byPath.keys()));
  const { refEdges, referrers } = indexRefs(model.files, defs);
  return { model, byPath, defs, imports, importers, refEdges, referrers };
}

/** Definitions of a name; `Class.method` narrows to methods of that container. */
export function findDefs(graph: RepoGraph, query: string): readonly SymbolRef[] {
  const dot = query.lastIndexOf(".");
  if (dot > 0) {
    const container = query.slice(0, dot);
    return (graph.defs.get(query.slice(dot + 1)) ?? []).filter(
      (d) => d.symbol.container === container,
    );
  }
  return graph.defs.get(query) ?? [];
}

/** The innermost definition that contains a line: the last symbol at or above it. */
export function enclosingSymbol(file: FileEntry, line: number): SymbolDef | undefined {
  let best: SymbolDef | undefined;
  for (const s of file.symbols) if (s.line <= line) best = s;
  return best;
}
