import { tokenize } from "./bm25";
import {
  type Columns,
  dot,
  orthonormalize,
  rng,
  type Sparse,
  symmetricEigen,
  times,
  timesT,
  weigh,
} from "./lsa-math";
import type { FileEntry } from "./model";

/**
 * A dense semantic index without a model download or an API: latent semantic analysis (a truncated SVD of the
 * term-by-document TF-IDF matrix). Terms that occur in the same files land near each other, so "spend cap"
 * finds `evaluateBudget` through the files where cap, spend and budget appear together. Deterministic (a seeded
 * random projection), pure, and small enough to rebuild when the model changes. A learned embedding model can
 * replace it behind the same `SemanticIndex` shape (ADR-0016).
 */
export interface SemanticIndex {
  readonly dims: number;
  readonly paths: readonly string[];
  /** Unit vectors, one per path, `dims` long. */
  readonly vectors: readonly Float64Array[];
  /** term → its row of U·Σ⁻¹ (folding a query into the space is a sum of these). */
  readonly terms: ReadonlyMap<string, Float64Array>;
  readonly idf: ReadonlyMap<string, number>;
}

export interface SemanticDoc {
  readonly path: string;
  readonly tokens: readonly string[];
}

/** One document per file: its path, definition names and doc comments, and the identifiers it uses. */
export function semanticDocs(files: readonly FileEntry[]): SemanticDoc[] {
  return files.map((f) => ({
    path: f.path,
    tokens: [
      ...tokenize(f.path),
      ...f.symbols.flatMap((s) => [...tokenize(s.name), ...tokenize(s.doc ?? "")]),
      ...f.refs.flatMap((r) => tokenize(r)),
    ],
  }));
}

/** Latent dimensions kept, and extra columns sampled for accuracy (randomized SVD, Halko et al. 2011). */
export const LSA_DIMS = 96;
const OVERSAMPLE = 16;
const POWER_ITERATIONS = 2;

function unit(v: Float64Array): Float64Array {
  let n = 0;
  for (const x of v) n += x * x;
  n = Math.sqrt(n);
  if (n > 0) for (let i = 0; i < v.length; i += 1) v[i] = (v[i] ?? 0) / n;
  return v;
}

/** An orthonormal basis Q (terms × k, by column) for the range of A, by randomized power iteration. */
function rangeBasis(cols: Sparse, rows: number, k: number): Columns {
  const r = rng(0x5eed);
  const omega = Array.from({ length: k }, () =>
    Float64Array.from({ length: cols.ptr.length - 1 }, r),
  );
  let q = times(cols, rows, omega);
  orthonormalize(q);
  for (let i = 0; i < POWER_ITERATIONS; i += 1) {
    const z = timesT(cols, q);
    orthonormalize(z);
    q = times(cols, rows, z);
    orthonormalize(q);
  }
  return q;
}

/** Rows of a column-major matrix times the kept eigenvectors: row i of M·W[:, keep]. */
function projectRows(
  m: Columns,
  rows: number,
  w: readonly Float64Array[],
  keep: readonly number[],
) {
  const out = Array.from({ length: rows }, () => new Float64Array(keep.length));
  keep.forEach((c, d) => {
    for (let j = 0; j < m.length; j += 1) {
      const wjc = (w[j] as Float64Array)[c] as number;
      const mj = m[j] as Float64Array;
      for (let i = 0; i < rows; i += 1) {
        const o = out[i] as Float64Array;
        o[d] = (o[d] as number) + wjc * (mj[i] as number);
      }
    }
  });
  return out;
}

/** Builds the index; an empty one when there are too few documents or terms to factor. */
export function buildSemantic(docs: readonly SemanticDoc[], dims = LSA_DIMS): SemanticIndex {
  const { vocab, idf, cols } = weigh(docs);
  const k = Math.min(dims + OVERSAMPLE, vocab.length, docs.length);
  if (k < 4) return { dims: 0, paths: [], vectors: [], terms: new Map(), idf };
  const q = rangeBasis(cols, vocab.length, k);
  const bt = timesT(cols, q); // k columns over docs: Bᵀ, where B = Qᵀ·A
  const gram = bt.map((x) => Float64Array.from(bt, (y) => dot(x, y)));
  const { values, vectors } = symmetricEigen(gram);
  const keep = values
    .map((v, i) => [v, i] as const)
    .sort((x, y) => y[0] - x[0])
    .slice(0, Math.min(dims, k))
    .map(([, i]) => i);
  const termRows = projectRows(q, vocab.length, vectors, keep);
  return {
    dims: keep.length,
    paths: docs.map((d) => d.path),
    vectors: projectRows(bt, docs.length, vectors, keep).map(unit),
    terms: new Map(vocab.map((t, i) => [t, termRows[i] as Float64Array] as const)),
    idf,
  };
}

/** Cosine similarity of a text to every document, best first; terms outside the vocabulary are ignored. */
export interface SemanticHit {
  readonly path: string;
  readonly score: number;
}

export function searchSemantic(index: SemanticIndex, text: string, limit: number): SemanticHit[] {
  if (index.dims === 0) return [];
  const q = new Float64Array(index.dims);
  const counts = new Map<string, number>();
  for (const t of tokenize(text)) counts.set(t, (counts.get(t) ?? 0) + 1);
  let any = false;
  for (const [t, n] of counts) {
    const row = index.terms.get(t);
    if (!row) continue;
    any = true;
    const w = (1 + Math.log(n)) * (index.idf.get(t) ?? 0);
    for (let i = 0; i < index.dims; i += 1) q[i] = (q[i] ?? 0) + w * (row[i] ?? 0);
  }
  if (!any) return [];
  unit(q);
  return index.vectors
    .map((v, i) => ({ path: index.paths[i] ?? "", score: dot(v, q) }))
    .filter((h) => h.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}
