import type { ChangedFile } from "./diff";
import { enclosingSymbol, type RepoGraph } from "./graph";
import { resolveImport } from "./imports";
import type { SymbolDef } from "./model";
import { testsFor } from "./tests-map";

/** Lists in the impact are cut to keep the prompt section short; the cut is counted. */
const MAX_LIST = 6;

export interface Listed {
  readonly shown: readonly string[];
  readonly more: number;
}

export interface FileImpact {
  readonly path: string;
  /** Definitions whose body the diff edits (by enclosing line), public ones first. */
  readonly touched: readonly SymbolDef[];
  /** Files outside the change that import this file. */
  readonly dependents: Listed;
  /** Per touched public name: files outside the change that refer to it. */
  readonly callers: readonly { readonly name: string; readonly files: Listed }[];
  /** Linked tests, and whether the change edits each one. */
  readonly tests: readonly { readonly path: string; readonly inChange: boolean }[];
}

export interface ChangeImpact {
  readonly files: readonly FileImpact[];
  /** Changed source files (not tests) that no test in the change is linked to. */
  readonly untested: readonly string[];
  /** Deleted files that files outside the change still import (they would break). */
  readonly orphaned: readonly { readonly path: string; readonly importers: Listed }[];
  /** Changed paths the model does not index (docs, config, unknown languages). */
  readonly unindexed: readonly string[];
}

function listed(all: readonly string[]): Listed {
  return { shown: all.slice(0, MAX_LIST), more: Math.max(0, all.length - MAX_LIST) };
}

function touchedSymbols(graph: RepoGraph, change: ChangedFile): SymbolDef[] {
  const file = graph.byPath.get(change.path);
  if (!file) return [];
  const seen = new Map<string, SymbolDef>();
  for (const line of [...change.lines, ...change.hunks]) {
    const s = enclosingSymbol(file, line);
    if (s) seen.set(`${s.line}:${s.name}`, s);
  }
  return [...seen.values()].sort(
    (a, b) => Number(b.exported) - Number(a.exported) || a.line - b.line,
  );
}

function fileImpact(graph: RepoGraph, change: ChangedFile, inChange: ReadonlySet<string>) {
  const touched = touchedSymbols(graph, change);
  const outside = (paths: readonly string[]) =>
    [...new Set(paths)].filter((p) => !inChange.has(p) && p !== change.path).sort();
  const callers = touched
    .filter((s) => s.exported)
    .slice(0, MAX_LIST)
    .map((s) => ({ name: s.name, files: listed(outside(graph.referrers.get(s.name) ?? [])) }))
    .filter((c) => c.files.shown.length > 0);
  const tests = testsFor(graph, change.path).map((t) => ({
    path: t.path,
    inChange: inChange.has(t.path),
  }));
  return {
    path: change.path,
    touched,
    dependents: listed(outside(graph.importers.get(change.path) ?? [])),
    callers,
    tests,
  };
}

/** Files outside the change whose imports still resolve to a deleted path. */
function orphansOf(graph: RepoGraph, deleted: readonly string[], inChange: ReadonlySet<string>) {
  if (deleted.length === 0) return [];
  const gone = new Set(deleted);
  const paths = new Set([...graph.byPath.keys(), ...deleted]);
  const hits = new Map<string, string[]>();
  for (const f of graph.model.files) {
    if (inChange.has(f.path)) continue;
    for (const spec of f.imports) {
      const to = resolveImport(f.lang, f.path, spec, paths);
      if (to !== undefined && gone.has(to)) hits.set(to, [...(hits.get(to) ?? []), f.path]);
    }
  }
  return [...hits.entries()].map(([path, importers]) => ({
    path,
    importers: listed([...new Set(importers)].sort()),
  }));
}

/**
 * What a change reaches beyond its own lines (ADR-0016): who imports the changed files, who refers to the
 * definitions it edits, and which linked tests it does or does not touch. Static and approximate (names, not
 * types), so it points a reviewer at places to check; it never decides on its own.
 */
export function changeImpact(graph: RepoGraph, changes: readonly ChangedFile[]): ChangeImpact {
  const inChange = new Set(changes.flatMap((c) => [c.path, c.oldPath]).filter((p) => p !== ""));
  const live = changes.filter((c) => !c.deleted && graph.byPath.has(c.path));
  const files = live
    .filter((c) => !graph.byPath.get(c.path)?.test)
    .map((c) => fileImpact(graph, c, inChange));
  const untested = files
    .filter((f) => f.touched.length > 0 && !f.tests.some((t) => t.inChange))
    .map((f) => f.path);
  const deleted = changes.flatMap((c) =>
    c.deleted ? [c.path] : c.oldPath !== "" && c.oldPath !== c.path ? [c.oldPath] : [],
  );
  const unindexed = changes.filter((c) => !c.deleted && !live.includes(c)).map((c) => c.path);
  return { files, untested, orphaned: orphansOf(graph, deleted, inChange), unindexed };
}
