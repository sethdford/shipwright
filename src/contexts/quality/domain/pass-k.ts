/** Binomial coefficient C(n, k). Exact for the small n of an eval corpus. */
export function choose(n: number, k: number): number {
  if (!Number.isInteger(n) || !Number.isInteger(k) || k < 0 || n < 0 || k > n) return 0;
  const m = Math.min(k, n - k);
  let value = 1;
  for (let i = 1; i <= m; i++) value = (value * (n - m + i)) / i;
  return Math.round(value);
}

/**
 * Unbiased estimate of pass^k: the chance that k independent runs of one case all pass, given
 * `passes` passing runs out of `runs` (the τ-bench estimator C(c, k) / C(n, k)). With runs = k it
 * is 1 when every run passed and 0 otherwise. Returns null when there are fewer runs than k.
 */
export function passHatK(runs: number, passes: number, k: number): number | null {
  if (!Number.isInteger(k) || k < 1 || runs < k || passes < 0 || passes > runs) return null;
  return choose(passes, k) / choose(runs, k);
}
