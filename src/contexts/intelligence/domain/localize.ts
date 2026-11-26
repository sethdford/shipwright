import { type Bm25Index, buildBm25, searchBm25, tokenize } from "./bm25";
import type { RepoGraph } from "./graph";
import type { SymbolDef } from "./model";
import { rankFiles } from "./rank";

export interface Entity {
  readonly path: string;
  readonly symbol?: SymbolDef;
}

/**
 * One search document per file and per definition (LocAgent's entity index): the name counts three times, then
 * its container, path, signature and doc comment, so a query in prose finds code named in another style.
 */
export function entityIndex(graph: RepoGraph): Bm25Index<Entity> {
  const docs = graph.model.files.flatMap((f) => {
    const pathTokens = tokenize(f.path);
    const fileDoc = { item: { path: f.path }, tokens: [...pathTokens, ...pathTokens] };
    const symDocs = f.symbols.map((s) => {
      const name = tokenize(s.name);
      const tokens = [...name, ...name, ...name, ...tokenize(s.container ?? ""), ...pathTokens];
      tokens.push(...tokenize(s.signature), ...tokenize(s.doc ?? ""));
      return { item: { path: f.path, symbol: s }, tokens };
    });
    return [fileDoc, ...symDocs];
  });
  return buildBm25(docs);
}

export interface LocalizedFile {
  readonly path: string;
  readonly score: number;
  readonly why: readonly string[];
  readonly symbols: readonly SymbolDef[];
  readonly test: boolean;
}

interface Evidence {
  lexical: number;
  named: boolean;
  terms: Set<string>;
  symbols: Map<string, SymbolDef>;
}

function evidenceFor(map: Map<string, Evidence>, path: string): Evidence {
  let e = map.get(path);
  if (!e) {
    e = { lexical: 0, named: false, terms: new Set(), symbols: new Map() };
    map.set(path, e);
  }
  return e;
}

/** Paths and defined names the text mentions outright: the strongest localization signal there is. */
function mentions(graph: RepoGraph, text: string, ev: Map<string, Evidence>): void {
  for (const f of graph.model.files) {
    const base = f.path.slice(f.path.lastIndexOf("/") + 1);
    if (
      text.includes(f.path) ||
      (base.length >= 6 && new RegExp(`\\b${escapeRe(base)}\\b`).test(text))
    ) {
      evidenceFor(ev, f.path).named = true;
    }
  }
  const words = new Set(text.match(/[A-Za-z_][A-Za-z0-9_]{3,}/g) ?? []);
  for (const w of words) {
    const defs = graph.defs.get(w);
    if (!defs || defs.length > 6 || !/[a-z][A-Z]|_|^[A-Z][a-z]+[A-Z]/.test(w)) continue;
    for (const d of defs) {
      const e = evidenceFor(ev, d.path);
      e.named = true;
      e.symbols.set(d.symbol.name, d.symbol);
    }
  }
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function lexical(index: Bm25Index<Entity>, text: string, ev: Map<string, Evidence>): void {
  const qTerms = new Set(tokenize(text));
  const hits = searchBm25(index, text, 80);
  const top = hits[0]?.score ?? 1;
  for (const h of hits) {
    const e = evidenceFor(ev, h.item.path);
    const s = h.score / top;
    // The best hit in a file counts fully, further hits add less (a big file is not more relevant per se).
    e.lexical = Math.max(e.lexical, s) + 0.1 * Math.min(e.lexical, s);
    if (h.item.symbol && e.symbols.size < 8) e.symbols.set(h.item.symbol.name, h.item.symbol);
    for (const t of tokenize(h.item.symbol?.name ?? h.item.path)) if (qTerms.has(t)) e.terms.add(t);
  }
}

function seedsOf(ev: ReadonlyMap<string, Evidence>): Map<string, number> {
  const seeds = new Map<string, number>();
  for (const [path, e] of ev) seeds.set(path, (e.named ? 2 : 0) + e.lexical);
  return seeds;
}

function whyOf(e: Evidence | undefined, graphRank: number): string[] {
  const why: string[] = [];
  if (e?.named) why.push("named in the task");
  if (e && e.terms.size > 0) why.push(`matches ${[...e.terms].slice(0, 4).join(", ")}`);
  if (graphRank > 0.5) why.push("close in the code graph to the matches");
  return why;
}

function maxOf(values: Iterable<number>): number {
  let m = 0;
  for (const v of values) m = Math.max(m, v);
  return m || 1;
}

/**
 * Hierarchical localization (Agentless, LocAgent): find the files and then the definitions a task is about.
 * Lexical hits and outright mentions seed a personalized PageRank, so files the hits depend on, or that depend
 * on them, rise too. Returns at most `limit` files, best first.
 */
export function localize(
  graph: RepoGraph,
  index: Bm25Index<Entity>,
  text: string,
  limit = 10,
): LocalizedFile[] {
  const ev = new Map<string, Evidence>();
  mentions(graph, text, ev);
  lexical(index, text, ev);
  if (ev.size === 0) return [];
  const rank = rankFiles(graph, seedsOf(ev));
  const topRank = maxOf(rank.values());
  const out: LocalizedFile[] = [];
  for (const f of graph.model.files) {
    const e = ev.get(f.path);
    const g = (rank.get(f.path) ?? 0) / topRank;
    const score = (e?.named ? 1 : 0) + 0.6 * (e?.lexical ?? 0) + 0.4 * g;
    if (score < 0.05 || (!e && g < 0.2)) continue;
    const symbols = e ? [...e.symbols.values()] : f.symbols.filter((s) => s.exported).slice(0, 3);
    out.push({ path: f.path, score, why: whyOf(e, g), symbols: symbols.slice(0, 6), test: f.test });
  }
  return out.sort((a, b) => b.score - a.score || a.path.localeCompare(b.path)).slice(0, limit);
}
