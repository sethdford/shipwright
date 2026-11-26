export const BENCH_SUBS = [
  "plan",
  "run",
  "report",
  "validate",
  "export-eval",
  "export-swebench",
  "import-swebench",
  "sample-swebench",
  "mine-holdout",
] as const;
export type BenchSub = (typeof BENCH_SUBS)[number];

export interface BenchFlags {
  readonly sub: BenchSub;
  readonly values: Readonly<Record<string, string>>;
  readonly setup: readonly (readonly string[])[];
  readonly trials: number;
  readonly k: number;
  readonly trial: number;
}

const NEEDS: Record<BenchSub, readonly string[]> = {
  plan: ["tasks", "arms"],
  run: ["tasks", "arms", "out", "budget"],
  report: ["tasks", "arms", "out"],
  validate: ["tasks", "out"],
  "export-eval": ["out", "arm"],
  "export-swebench": ["out", "arm"],
  "import-swebench": ["out", "arm", "report"],
  "sample-swebench": ["from", "n"],
  "mine-holdout": ["repo", "since"],
};
const VALUE_FLAGS = [
  "tasks",
  "arms",
  "out",
  "budget",
  "arm",
  "report",
  "from",
  "n",
  "seed",
  "name",
  "repo",
  "since",
  "max",
  "format",
  "clone-url",
  "source",
  "problems",
];
const INT = (lo: number, hi: number) => (v: string) =>
  /^\d+$/.test(v) && Number(v) >= lo && Number(v) <= hi;

function checkValues(values: Record<string, string>): string | null {
  if (values.budget !== undefined && !/^\d+(\.\d+)?$/.test(values.budget))
    return "--budget must be a dollar amount";
  if (values.n !== undefined && !INT(0, 10_000)(values.n)) return "--n must be 0 to 10000";
  if (values.seed !== undefined && !INT(0, 2 ** 31)(values.seed))
    return "--seed must be a non-negative integer";
  if (values.max !== undefined && !INT(1, 2000)(values.max)) return "--max must be 1 to 2000";
  if (values.since !== undefined && Number.isNaN(Date.parse(values.since)))
    return "--since must be a date";
  if (values.source !== undefined && !["pulls", "commits"].includes(values.source))
    return "--source must be pulls or commits";
  if (values.format !== undefined && !["md", "html", "json"].includes(values.format))
    return "--format must be md, html or json";
  return null;
}

function parseNumberFlag(flag: string, value: string, out: Record<string, number>): string | null {
  const limits: Record<string, [number, number]> = {
    "--trials": [1, 10],
    "--k": [1, 10],
    "--trial": [1, 10],
  };
  const [lo, hi] = limits[flag] ?? [0, 0];
  if (!INT(lo, hi)(value)) return `${flag} must be ${lo} to ${hi}`;
  out[flag.slice(2)] = Number(value);
  return null;
}

/** Parses `bench <sub> [--flag value ...]`. Returns a message on a usage error. */
export function parseBenchFlags(args: readonly string[]): BenchFlags | string {
  const [sub, ...rest] = args;
  if (!BENCH_SUBS.includes(sub as BenchSub))
    return `expected one of ${BENCH_SUBS.join(", ")}, got: ${sub ?? "nothing"}`;
  const values: Record<string, string> = {};
  const nums: Record<string, number> = { trials: 1, k: 1, trial: 1 };
  const setup: string[][] = [];
  for (let i = 0; i < rest.length; i++) {
    const flag = rest[i] ?? "";
    const value = rest[++i];
    if (value === undefined || value.startsWith("--")) return `${flag} needs a value`;
    if (["--trials", "--k", "--trial"].includes(flag)) {
      const bad = parseNumberFlag(flag, value, nums);
      if (bad) return bad;
    } else if (flag === "--setup") {
      setup.push(value.split(/\s+/).filter((t) => t.length > 0));
    } else if (VALUE_FLAGS.includes(flag.slice(2)) && flag.startsWith("--")) {
      values[flag.slice(2)] = value;
    } else {
      return `unknown option: ${flag}`;
    }
  }
  const missing = NEEDS[sub as BenchSub].find((n) => values[n] === undefined);
  if (missing) return `--${missing} is required`;
  const bad = checkValues(values);
  if (bad) return bad;
  return {
    sub: sub as BenchSub,
    values,
    setup,
    trials: nums.trials ?? 1,
    k: nums.k ?? 1,
    trial: nums.trial ?? 1,
  };
}
