/** mulberry32: a small seeded PRNG, so a sample is the same on every machine. */
function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * A deterministic sample of `n` items: sorted by `key` first (input order never matters), then a
 * seeded Fisher-Yates shuffle, then the first n, returned in key order.
 */
export function seededSample<T>(
  items: readonly T[],
  n: number,
  seed: number,
  key: (t: T) => string,
): T[] {
  const sorted = [...items].sort((x, y) => (key(x) < key(y) ? -1 : key(x) > key(y) ? 1 : 0));
  const next = rng(seed);
  for (let i = sorted.length - 1; i > 0; i--) {
    const j = Math.floor(next() * (i + 1));
    [sorted[i], sorted[j]] = [sorted[j] as T, sorted[i] as T];
  }
  return sorted.slice(0, n).sort((x, y) => (key(x) < key(y) ? -1 : 1));
}
