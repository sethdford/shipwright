import { compareEval, type RatchetReport, summarizeEval } from "../../contexts/quality";
import type { Command, CommandContext } from "../command";
import { isHelpRequest, usageError } from "../shared";

const usage = `USAGE
  shipwright eval score --results FILE [--k N] [--json]
  shipwright eval ratchet --incumbent FILE --candidate FILE [--k N] [--json]

DESCRIPTION
  Scores eval runs and applies the paired ratchet rule (Wave 2 plan W2-13). Pure: it reads the
  files and writes nothing. A results file is JSON:
    { "policy": "routing-v1",
      "runs": [ { "case": "c01", "pass": true, "costUsd": 0.42 }, ... ],
      "vetoes": { "fenceViolations": 0, "protectedPathTouched": false, "oracleTampering": false } }
  Every case needs at least k runs. pass^k is the unbiased estimate C(passes,k)/C(runs,k).

  ratchet accepts the candidate when it is non-inferior (losses - wins <= 0 and losses <= 1) and
  either superior (exact one-sided sign test, p <= 0.05) or cheaper (median paired cost ratio
  <= 0.9). A fence violation, a protected-path touch or oracle tampering rejects it outright.

OPTIONS
  --k N    Runs that must all pass, 1 to 10 (default 3)
  --json   Print the full result as JSON

EXIT CODES
  0  scored, or candidate accepted      3  candidate rejected
  1  could not read or score the files  2  usage error`;

type Flags = {
  readonly sub: string;
  readonly files: Record<string, string>;
  readonly k: number;
  readonly json: boolean;
};

function parseFlags(args: readonly string[]): Flags | string {
  const [sub, ...rest] = args;
  const files: Record<string, string> = {};
  let k = 3;
  let json = false;
  for (let i = 0; i < rest.length; i++) {
    const flag = rest[i] ?? "";
    if (flag === "--json") {
      json = true;
      continue;
    }
    const value = rest[++i];
    if (value === undefined || value.startsWith("--")) return `${flag} needs a value`;
    if (flag === "--k") {
      if (!/^([1-9]|10)$/.test(value)) return "--k must be 1 to 10";
      k = Number(value);
    } else if (["--results", "--incumbent", "--candidate"].includes(flag)) {
      files[flag.slice(2)] = value;
    } else {
      return `unknown option: ${flag}`;
    }
  }
  const need =
    sub === "score" ? ["results"] : sub === "ratchet" ? ["incumbent", "candidate"] : null;
  if (need === null) return `expected score or ratchet, got: ${sub ?? "nothing"}`;
  const missing = need.find((n) => files[n] === undefined);
  if (missing) return `--${missing} is required`;
  return { sub: sub ?? "", files, k, json };
}

async function readJson(ctx: CommandContext, path: string): Promise<unknown | Error> {
  const raw = await ctx.files().readText(path);
  if (!raw.ok) return new Error(`cannot read ${path}: ${raw.error.message}`);
  try {
    return JSON.parse(raw.value);
  } catch {
    return new Error(`${path} is not JSON`);
  }
}

function describe(r: RatchetReport): string {
  const v = r.verdict;
  const mark = v.accept ? "✓ accept" : "✗ reject";
  const cost = v.medianCostRatio === null ? "—" : v.medianCostRatio.toFixed(3);
  return [
    `${mark} ${r.candidate} over ${r.incumbent}: ${v.reason}`,
    `  cases ${v.cases} · wins ${v.wins} · losses ${v.losses} · ties ${v.ties}`,
    `  sign test p ${v.signTestP.toFixed(4)} · median cost ratio ${cost}`,
  ].join("\n");
}

async function run(flags: Flags, ctx: CommandContext): Promise<number> {
  const { io } = ctx;
  const loaded: Record<string, unknown> = {};
  for (const [name, path] of Object.entries(flags.files)) {
    const value = await readJson(ctx, path);
    if (value instanceof Error) {
      io.err(`✗ eval: ${value.message}`);
      return 1;
    }
    loaded[name] = value;
  }
  if (flags.sub === "score") {
    const r = summarizeEval(loaded.results, flags.k);
    if (!r.ok) return fail(ctx, r.reason);
    const s = r.value;
    const line = `${s.policy}: pass^${s.k} ${(s.meanPassK * 100).toFixed(1)}% over ${s.cases.length} case(s), ${s.runs} run(s), $${s.totalCostUsd.toFixed(2)}`;
    io.out(flags.json ? JSON.stringify(s, null, 2) : line);
    return 0;
  }
  const r = compareEval(loaded.incumbent, loaded.candidate, flags.k);
  if (!r.ok) return fail(ctx, r.reason);
  io.out(flags.json ? JSON.stringify(r.value, null, 2) : describe(r.value));
  return r.value.verdict.accept ? 0 : 3;
}

function fail(ctx: CommandContext, reason: string): number {
  ctx.io.err(`✗ eval: ${reason}`);
  return 1;
}

export const evalCommand: Command = {
  name: "eval",
  aliases: [],
  summary: "Score eval runs (pass^k) and apply the paired ratchet rule to a candidate policy",
  usage,
  async run(args, ctx) {
    if (isHelpRequest(args, ["score", "ratchet"])) {
      ctx.io.out(usage);
      return 0;
    }
    const flags = parseFlags(args);
    if (typeof flags === "string") return usageError(ctx.io, usage, flags);
    return run(flags, ctx);
  },
};
