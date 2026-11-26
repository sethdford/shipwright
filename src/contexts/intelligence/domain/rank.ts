import type { RepoGraph } from "./graph";

const DAMPING = 0.85;
const ITERATIONS = 30;
/** An import is a firmer edge than a shared name. */
const IMPORT_WEIGHT = 2;

type Edges = Map<string, Map<string, number>>;

function addEdge(edges: Edges, from: string, to: string, w: number): void {
  let out = edges.get(from);
  if (!out) {
    out = new Map();
    edges.set(from, out);
  }
  out.set(to, (out.get(to) ?? 0) + w);
}

/** Import and reference edges in one weighted graph, from a file to the files it depends on. */
function combinedEdges(graph: RepoGraph): Edges {
  const edges: Edges = new Map();
  for (const [from, tos] of graph.imports)
    for (const to of tos) addEdge(edges, from, to, IMPORT_WEIGHT);
  for (const [from, tos] of graph.refEdges) for (const [to, w] of tos) addEdge(edges, from, to, w);
  return edges;
}

function normalize(
  seeds: ReadonlyMap<string, number>,
  nodes: readonly string[],
): Map<string, number> {
  const total = [...seeds.values()].reduce((a, b) => a + b, 0);
  const out = new Map<string, number>();
  if (total <= 0) {
    for (const n of nodes) out.set(n, 1 / nodes.length);
    return out;
  }
  for (const [n, v] of seeds) if (v > 0) out.set(n, v / total);
  return out;
}

function step(
  rank: ReadonlyMap<string, number>,
  edges: Edges,
  teleport: ReadonlyMap<string, number>,
  nodes: readonly string[],
): Map<string, number> {
  const next = new Map<string, number>();
  let dangling = 0;
  for (const n of nodes) {
    const r = rank.get(n) ?? 0;
    const out = edges.get(n);
    const total = out ? [...out.values()].reduce((a, b) => a + b, 0) : 0;
    if (!out || total <= 0) {
      dangling += r;
      continue;
    }
    for (const [to, w] of out) next.set(to, (next.get(to) ?? 0) + DAMPING * r * (w / total));
  }
  for (const [n, t] of teleport)
    next.set(n, (next.get(n) ?? 0) + (1 - DAMPING + DAMPING * dangling) * t);
  return next;
}

/**
 * Personalized PageRank over files. With no seeds it is plain PageRank (the files the most code depends on);
 * with seeds (files the issue names or search hits) the rank flows from them along dependencies, which is the
 * repo-map ranking Aider uses and the graph expansion step of graph-guided localization (LocAgent, LARGER).
 */
export function rankFiles(
  graph: RepoGraph,
  seeds: ReadonlyMap<string, number> = new Map(),
): Map<string, number> {
  const nodes = graph.model.files.map((f) => f.path);
  if (nodes.length === 0) return new Map();
  const edges = combinedEdges(graph);
  const teleport = normalize(seeds, nodes);
  let rank: Map<string, number> = new Map(teleport);
  for (let i = 0; i < ITERATIONS; i += 1) rank = step(rank, edges, teleport, nodes);
  return rank;
}

export function topRanked(
  rank: ReadonlyMap<string, number>,
  n: number,
): readonly [string, number][] {
  return [...rank.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, n);
}
