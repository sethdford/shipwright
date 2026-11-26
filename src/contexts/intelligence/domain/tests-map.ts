import type { RepoGraph } from "./graph";

/** A test "uses" a file when it refers to at least one specific name (or several plain ones) it defines. */
const USES_MIN = 2;
const MAX_USES = 5;

export interface TestLink {
  readonly path: string;
  readonly via: "imports" | "name" | "uses";
}

function stemOf(path: string): string {
  const base = path.slice(path.lastIndexOf("/") + 1);
  return base
    .replace(/\.[^.]+$/, "")
    .replace(/(\.|_|-)(test|spec)$/i, "")
    .replace(/^test_/, "")
    .replace(/Test$/, "")
    .toLowerCase();
}

/**
 * Tests that exercise a source file, strongest link first: the test imports it; the test is named after it
 * (`x.test.ts`, `test_x.py`, `x_test.go`, `sw-x-test.sh`); or the test uses names only that file defines.
 * This is the static test-impact map; coverage data can sharpen it later without changing callers.
 */
export function testsFor(graph: RepoGraph, path: string): TestLink[] {
  const out = new Map<string, TestLink["via"]>();
  for (const imp of graph.importers.get(path) ?? []) {
    if (graph.byPath.get(imp)?.test) out.set(imp, "imports");
  }
  const stem = stemOf(path);
  for (const f of graph.model.files) {
    if (!f.test || out.has(f.path) || f.path === path) continue;
    if (stem.length >= 3 && stemOf(f.path) === stem) out.set(f.path, "name");
    else if ((graph.refEdges.get(f.path)?.get(path) ?? 0) >= USES_MIN) out.set(f.path, "uses");
  }
  const order = { imports: 0, name: 1, uses: 2 } as const;
  const links = [...out.entries()]
    .map(([p, via]) => ({ path: p, via, w: graph.refEdges.get(p)?.get(path) ?? 0 }))
    .sort((a, b) => order[a.via] - order[b.via] || b.w - a.w || a.path.localeCompare(b.path));
  const strong = links.filter((l) => l.via !== "uses");
  const weak = links.filter((l) => l.via === "uses").slice(0, MAX_USES);
  return [...strong, ...weak].map(({ path: p, via }) => ({ path: p, via }));
}

/** The source files a test covers: what it imports, plus its namesake. */
export function sourcesFor(graph: RepoGraph, testPath: string): string[] {
  const out = new Set(
    (graph.imports.get(testPath) ?? []).filter((p) => !graph.byPath.get(p)?.test),
  );
  const stem = stemOf(testPath);
  for (const f of graph.model.files) if (!f.test && stemOf(f.path) === stem) out.add(f.path);
  return [...out].sort();
}
