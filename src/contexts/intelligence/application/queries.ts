import { searchBm25 } from "../domain/bm25";
import { enclosingSymbol, findDefs } from "../domain/graph";
import { localize } from "../domain/localize";
import type { SymbolDef } from "../domain/model";
import { rankFiles, topRanked } from "../domain/rank";
import { renderMap } from "../domain/render";
import { sourcesFor, testsFor } from "../domain/tests-map";
import { ownershipOf } from "./owners";
import type { RepoSession, Snapshot } from "./session";

const MAX_REF_LINES = 60;

function sym(s: SymbolDef): string {
  const name = s.container ? `${s.container}.${s.name}` : s.name;
  return `${s.line}: ${s.kind} ${name}${s.exported ? "" : " (private)"} — ${s.signature}`;
}

export function searchText(snap: Snapshot, query: string, limit: number): string {
  const hits = searchBm25(snap.index, query, limit);
  if (hits.length === 0) return `No matches for "${query}".`;
  return hits
    .map((h) => {
      const where = h.item.symbol
        ? `${h.item.path}:${sym(h.item.symbol)}`
        : `${h.item.path} (file)`;
      const doc = h.item.symbol?.doc ? `\n    ${h.item.symbol.doc}` : "";
      return `${h.score.toFixed(2)}  ${where}${doc}`;
    })
    .join("\n");
}

export function definitionText(snap: Snapshot, name: string): string {
  const defs = findDefs(snap.graph, name);
  if (defs.length === 0) return `No definition of ${name} in the index. Try search.`;
  return defs
    .map((d) => `${d.path}:${sym(d.symbol)}${d.symbol.doc ? `\n    ${d.symbol.doc}` : ""}`)
    .join("\n");
}

function lineHits(text: string, name: string): number[] {
  const re = new RegExp(`(^|[^A-Za-z0-9_$])${name.replace(/[$]/g, "\\$")}([^A-Za-z0-9_$]|$)`);
  const out: number[] = [];
  text.split("\n").forEach((l, i) => {
    if (re.test(l)) out.push(i + 1);
  });
  return out;
}

/** Uses of a name, each with the definition it sits in: a caller list when the name is a function. */
export async function referencesText(
  session: RepoSession,
  snap: Snapshot,
  name: string,
): Promise<string> {
  const bare = name.slice(name.lastIndexOf(".") + 1);
  if (!/^[A-Za-z_$][\w$-]*$/.test(bare)) return `Not an identifier: ${name}`;
  const paths = new Set([
    ...(snap.graph.referrers.get(bare) ?? []),
    ...findDefs(snap.graph, bare).map((d) => d.path),
  ]);
  const out: string[] = [];
  for (const path of [...paths].sort()) {
    const text = await session.read(path);
    const file = snap.graph.byPath.get(path);
    if (!text.ok || !file) continue;
    for (const line of lineHits(text.value, bare)) {
      const inside = enclosingSymbol(file, line);
      const isDef = inside?.line === line && inside.name === bare;
      const code = (text.value.split("\n")[line - 1] ?? "").trim().slice(0, 140);
      out.push(
        `${path}:${line}${isDef ? " [definition]" : inside ? ` in ${inside.name}` : ""}: ${code}`,
      );
      if (out.length >= MAX_REF_LINES) return `${out.join("\n")}\n… more uses not shown`;
    }
  }
  return out.length > 0 ? out.join("\n") : `No uses of ${bare} found.`;
}

export function outlineText(snap: Snapshot, path: string): string {
  const f = snap.graph.byPath.get(path);
  if (!f) return `Not in the index: ${path}`;
  const head = `${path} (${f.lang}, ${f.lines} lines${f.test ? ", test" : ""})`;
  return [head, ...f.symbols.map((s) => `  ${sym(s)}`)].join("\n");
}

export function dependenciesText(snap: Snapshot, path: string): string {
  if (!snap.graph.byPath.has(path)) return `Not in the index: ${path}`;
  const imports = snap.graph.imports.get(path) ?? [];
  const importers = snap.graph.importers.get(path) ?? [];
  const uses = [...(snap.graph.refEdges.get(path) ?? new Map<string, number>()).entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([p]) => p);
  return [
    `imports (${imports.length}): ${imports.join(", ") || "none in this repository"}`,
    `imported by (${importers.length}): ${importers.join(", ") || "none"}`,
    `uses names from: ${uses.join(", ") || "none"}`,
  ].join("\n");
}

export function testsText(snap: Snapshot, path: string): string {
  const f = snap.graph.byPath.get(path);
  if (!f) return `Not in the index: ${path}`;
  if (f.test)
    return `${path} is a test. It covers: ${sourcesFor(snap.graph, path).join(", ") || "unknown"}`;
  const links = testsFor(snap.graph, path);
  if (links.length === 0) return `No tests found for ${path}. Consider adding one.`;
  return links.map((l) => `${l.path} (${l.via})`).join("\n");
}

export function ownersText(snap: Snapshot, path: string): string {
  const o = ownershipOf(snap.owners, snap.graph.model.authors, path);
  const authors = o.authors.map((a) => `${a.name} (${a.commits} commits, last ${a.last})`);
  return [
    `CODEOWNERS: ${o.owners.join(" ") || "none"}`,
    `recent authors: ${authors.join("; ") || "unknown"}`,
  ].join("\n");
}

/** The repo map, ranked toward `focus` (task text) when given, else by overall importance. */
export function repoMapText(snap: Snapshot, focus: string, budget: number): string {
  if (focus.trim().length === 0)
    return renderMap(snap.graph, topRanked(rankFiles(snap.graph), 200), budget);
  const located = localize(snap.graph, snap.index, focus, 200, snap.semantic(focus, 30));
  return renderMap(
    snap.graph,
    located.map((l) => [l.path, l.score] as const),
    budget,
  );
}

export function localizeText(snap: Snapshot, task: string, limit: number): string {
  const located = localize(snap.graph, snap.index, task, limit, snap.semantic(task, 30));
  if (located.length === 0)
    return "Nothing in the index matches this task. Try search with other words.";
  return located
    .map((l) => {
      const syms = l.symbols.slice(0, 4).map((s) => `\n    ${sym(s)}`);
      return `${l.score.toFixed(2)}  ${l.path}${l.test ? " [test]" : ""} — ${l.why.join("; ")}${syms.join("")}`;
    })
    .join("\n");
}
