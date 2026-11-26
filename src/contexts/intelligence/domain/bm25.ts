const K1 = 1.2;
const B = 0.75;

const STOP: ReadonlySet<string> = new Set(
  (
    "a an and are as at be by can do does for from get has have how i in into is it its not of on or set should " +
    "so that the this to use was we when where which will with you your src lib test tests ts js py sh"
  ).split(" "),
);

function stem(word: string): string {
  if (word.length > 5 && word.endsWith("ing")) return word.slice(0, -3);
  if (word.length > 4 && word.endsWith("ed")) return word.slice(0, -2);
  if (word.length > 3 && word.endsWith("s") && !word.endsWith("ss")) return word.slice(0, -1);
  return word;
}

/**
 * Words of code and prose: identifiers split at camelCase, snake_case, kebab-case, dots, slashes and digits,
 * lower-cased and lightly stemmed, so `evaluateBudget`, `evaluate_budget` and "budget evaluation" meet.
 */
export function tokenize(text: string): string[] {
  const out: string[] = [];
  for (const m of text.matchAll(/[A-Za-z][A-Za-z0-9]*/g)) {
    const parts = m[0]
      .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
      .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
      .replace(/[0-9]+/g, " ")
      .split(" ");
    for (const p of parts) {
      const w = p.toLowerCase();
      if (w.length >= 2 && !STOP.has(w)) out.push(stem(w));
    }
  }
  return out;
}

export interface Bm25Doc<T> {
  readonly item: T;
  readonly tokens: readonly string[];
}

export interface Bm25Index<T> {
  readonly docs: readonly Bm25Doc<T>[];
  readonly tf: readonly ReadonlyMap<string, number>[];
  readonly df: ReadonlyMap<string, number>;
  readonly avgLen: number;
}

export function buildBm25<T>(docs: readonly Bm25Doc<T>[]): Bm25Index<T> {
  const df = new Map<string, number>();
  const tf = docs.map((d) => {
    const counts = new Map<string, number>();
    for (const t of d.tokens) counts.set(t, (counts.get(t) ?? 0) + 1);
    for (const t of counts.keys()) df.set(t, (df.get(t) ?? 0) + 1);
    return counts;
  });
  const total = docs.reduce((a, d) => a + d.tokens.length, 0);
  return { docs, tf, df, avgLen: docs.length === 0 ? 0 : total / docs.length };
}

export interface Scored<T> {
  readonly item: T;
  readonly score: number;
}

/** Okapi BM25. Query terms are de-duplicated; documents with no matching term are left out. */
export function searchBm25<T>(index: Bm25Index<T>, query: string, limit: number): Scored<T>[] {
  const terms = [...new Set(tokenize(query))];
  const n = index.docs.length;
  const scored: Scored<T>[] = [];
  index.docs.forEach((doc, i) => {
    const counts = index.tf[i];
    if (!counts) return;
    let score = 0;
    for (const t of terms) {
      const f = counts.get(t) ?? 0;
      if (f === 0) continue;
      const df = index.df.get(t) ?? 0;
      const idf = Math.log(1 + (n - df + 0.5) / (df + 0.5));
      const len = doc.tokens.length / (index.avgLen || 1);
      score += (idf * f * (K1 + 1)) / (f + K1 * (1 - B + B * len));
    }
    if (score > 0) scored.push({ item: doc.item, score });
  });
  return scored.sort((a, b) => b.score - a.score).slice(0, limit);
}
