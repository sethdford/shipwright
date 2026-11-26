import type { SemanticDoc } from "./lsa";

/** A sparse terms × docs matrix in compressed-column form: column j holds entries ptr[j]..ptr[j+1]. */
export interface Sparse {
  readonly ptr: Int32Array;
  readonly row: Int32Array;
  readonly val: Float64Array;
}

export function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296 - 0.5;
  };
}

/** TF-IDF columns (one per document) over terms that occur in at least two and at most half the documents. */
export function weigh(docs: readonly SemanticDoc[]) {
  const df = new Map<string, number>();
  const counts = docs.map((d) => {
    const c = new Map<string, number>();
    for (const t of d.tokens) c.set(t, (c.get(t) ?? 0) + 1);
    for (const t of c.keys()) df.set(t, (df.get(t) ?? 0) + 1);
    return c;
  });
  const vocab = [...df.entries()]
    .filter(([, n]) => n >= 2 && n <= Math.max(2, docs.length / 2))
    .map(([t]) => t)
    .sort();
  const row = new Map(vocab.map((t, i) => [t, i] as const));
  const idf = new Map(vocab.map((t) => [t, Math.log(docs.length / (df.get(t) ?? 1))] as const));
  const ptr = new Int32Array(docs.length + 1);
  const rowIdx: number[] = [];
  const vals: number[] = [];
  counts.forEach((c, j) => {
    for (const [t, n] of c) {
      const i = row.get(t);
      if (i === undefined) continue;
      rowIdx.push(i);
      vals.push((1 + Math.log(n)) * (idf.get(t) ?? 0));
    }
    ptr[j + 1] = rowIdx.length;
  });
  const cols: Sparse = { ptr, row: Int32Array.from(rowIdx), val: Float64Array.from(vals) };
  return { vocab, idf, cols };
}

/** A dense matrix stored by column: `k` columns, each a Float64Array of the row count. */
export type Columns = Float64Array[];

/** Y = A·M for a sparse A (terms × docs) and dense M (docs × k, by column). */
export function times(a: Sparse, rows: number, m: Columns): Columns {
  const { ptr, row, val } = a;
  return m.map((mc) => {
    const yc = new Float64Array(rows);
    for (let j = 0; j + 1 < ptr.length; j += 1) {
      const w = mc[j] as number;
      if (w === 0) continue;
      const end = ptr[j + 1] as number;
      for (let p = ptr[j] as number; p < end; p += 1)
        yc[row[p] as number] = (yc[row[p] as number] as number) + (val[p] as number) * w;
    }
    return yc;
  });
}

/** Z = Aᵀ·Y for a sparse A and dense Y (terms × k, by column). */
export function timesT(a: Sparse, y: Columns): Columns {
  const { ptr, row, val } = a;
  const docs = ptr.length - 1;
  return y.map((yc) => {
    const z = new Float64Array(docs);
    for (let j = 0; j < docs; j += 1) {
      let s = 0;
      const end = ptr[j + 1] as number;
      for (let p = ptr[j] as number; p < end; p += 1)
        s += (val[p] as number) * (yc[row[p] as number] as number);
      z[j] = s;
    }
    return z;
  });
}

export function dot(a: Float64Array, b: Float64Array): number {
  let s = 0;
  for (let i = 0; i < a.length; i += 1) s += (a[i] as number) * (b[i] as number);
  return s;
}

/** Orthonormalizes columns in place (modified Gram–Schmidt over contiguous columns). */
export function orthonormalize(m: Columns): void {
  for (let c = 0; c < m.length; c += 1) {
    const mc = m[c] as Float64Array;
    for (let p = 0; p < c; p += 1) {
      const mp = m[p] as Float64Array;
      const d = dot(mc, mp);
      for (let i = 0; i < mc.length; i += 1) mc[i] = (mc[i] as number) - d * (mp[i] as number);
    }
    const norm = Math.sqrt(dot(mc, mc)) || 1;
    for (let i = 0; i < mc.length; i += 1) mc[i] = (mc[i] as number) / norm;
  }
}

/** Applies the Jacobi rotation that zeroes a[p][q] to `a` (both sides) and accumulates it into `v`. */
function rotate(a: Float64Array[], v: Float64Array[], p: number, q: number): void {
  const ap = a[p] as Float64Array;
  const aq = a[q] as Float64Array;
  const apq = ap[q] as number;
  if (Math.abs(apq) < 1e-15) return;
  const theta = ((aq[q] as number) - (ap[p] as number)) / (2 * apq);
  const t = Math.sign(theta || 1) / (Math.abs(theta) + Math.sqrt(theta * theta + 1));
  const c = 1 / Math.sqrt(t * t + 1);
  const s = t * c;
  for (const m of [a, v]) {
    for (const r of m) {
      const x = r[p] as number;
      const y = r[q] as number;
      r[p] = c * x - s * y;
      r[q] = s * x + c * y;
    }
  }
  for (let k = 0; k < ap.length; k += 1) {
    const x = ap[k] as number;
    const y = aq[k] as number;
    ap[k] = c * x - s * y;
    aq[k] = s * x + c * y;
  }
}

/** Eigenvalues and eigenvectors (as columns of `vectors`) of a small symmetric matrix, by cyclic Jacobi. */
export function symmetricEigen(
  a: Float64Array[],
  sweeps = 30,
): { values: number[]; vectors: Float64Array[] } {
  const n = a.length;
  const v = Array.from({ length: n }, (_, i) => {
    const r = new Float64Array(n);
    r[i] = 1;
    return r;
  });
  for (let s = 0; s < sweeps; s += 1) {
    let off = 0;
    for (let p = 0; p < n; p += 1)
      for (let q = p + 1; q < n; q += 1) off += ((a[p] as Float64Array)[q] as number) ** 2;
    if (off < 1e-18) break;
    for (let p = 0; p < n; p += 1) for (let q = p + 1; q < n; q += 1) rotate(a, v, p, q);
  }
  return { values: a.map((r, i) => r[i] as number), vectors: v };
}
