import {
  loadRoutingStats,
  type RouteRequest,
  type RoutingDecision,
  type RoutingStats,
  recordOutcome,
  routeIssue,
} from "../../contexts/intelligence";
import type { Command, CommandContext } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";
import {
  issueFromJson,
  modeOf,
  overridesOf,
  parseRouteFlags,
  positiveInt,
  type RouteFlags,
  resultOf,
  usd,
} from "./route-args";

const SUBCOMMANDS = ["decide", "outcome", "stats"] as const;
type Sub = (typeof SUBCOMMANDS)[number];

const usage = `USAGE
  shipwright route decide  (--issue-json FILE | --goal TEXT) [--issue N] [--repo OWNER/NAME]
                           [--remaining-usd X] [--failure-class C] [--mode shadow|apply]
                           [--template T] [--model M] [--effort E] [--attempts N] [--json]
  shipwright route outcome --decision ID --result success|failure [--failure-class C]
                           [--cost-usd X] [--pr N] [--json]
  shipwright route stats   [--json]

DESCRIPTION
  Adaptive compute router (ADR-0014). Predicts how hard an issue is from its text and labels, corrects
  that with the results of earlier routed runs, and picks the pipeline template, model, effort,
  number of parallel attempts and run budget from the routing table (routing-v1).

  decide   Prints the route and appends the decision, with every input, to the routing log. Values
           passed with --template, --model, --effort or --attempts are kept as given. --remaining-usd
           (money left under the daily cap) only lowers attempts and the cap; at 0 the action is
           "defer". --failure-class budget or max_turns (a retry) moves the route up one tier.
  outcome  Records how a routed run ended, so history and stats can use it.
  stats    Runs, success rate and cost per success for each tier.

  The bash pipeline calls decide at start and outcome at the end. SHIPWRIGHT_ROUTER=shadow (the
  default) logs the route without using it; apply uses it; off skips the router.

FILES
  ~/.shipwright/routing/decisions.jsonl   one decision or outcome per line

EXIT CODES
  0  done      1  could not read or write the routing log      2  usage error`;

const ALLOWED: Readonly<Record<Sub, readonly string[]>> = {
  decide: [
    "--issue-json",
    "--goal",
    "--issue",
    "--repo",
    "--remaining-usd",
    "--failure-class",
    "--mode",
    "--template",
    "--model",
    "--effort",
    "--attempts",
    "--json",
  ],
  outcome: ["--decision", "--result", "--failure-class", "--cost-usd", "--pr", "--json"],
  stats: ["--json"],
};

async function issueText(
  ctx: CommandContext,
  f: RouteFlags,
): Promise<RouteRequest["issueText"] | string | number> {
  const file = f.values["--issue-json"];
  const goal = f.values["--goal"];
  if ((file === undefined) === (goal === undefined))
    return "give exactly one of --issue-json or --goal";
  if (goal !== undefined) return { title: goal, body: "", labels: [] };
  const read = await ctx.files().readText(file as string);
  if (!read.ok) return adapterFailure(ctx.io, `read ${file}`, read.error);
  return issueFromJson(read.value);
}

/** Builds the request, or returns a usage message (string) or an exit code (number). */
async function decideRequest(
  ctx: CommandContext,
  f: RouteFlags,
): Promise<RouteRequest | string | number> {
  const text = await issueText(ctx, f);
  if (typeof text !== "object") return text;
  const mode = modeOf(f.values["--mode"], ctx.env.SHIPWRIGHT_ROUTER);
  const issue = positiveInt("--issue", f.values["--issue"]);
  const remaining = usd("--remaining-usd", f.values["--remaining-usd"]);
  const overrides = overridesOf(f.values);
  if (mode !== "shadow" && mode !== "apply") return mode;
  if (typeof issue === "string") return issue;
  if (typeof remaining === "string") return remaining;
  if (typeof overrides === "string") return overrides;
  const repo = f.values["--repo"];
  const failure = f.values["--failure-class"];
  return {
    issueText: text,
    mode,
    overrides,
    ...(typeof issue === "number" ? { issue } : {}),
    ...(repo === undefined ? {} : { repo }),
    ...(typeof remaining === "number" ? { remainingUsd: remaining } : {}),
    ...(failure === undefined ? {} : { previousFailure: failure }),
  };
}

export function renderDecision(d: RoutingDecision): readonly string[] {
  const a = d.applied;
  const lines = [
    `route ${d.id} (${d.policy}, ${d.mode}): ${d.difficulty.tier} (score ${d.difficulty.score}, prior ${d.difficulty.prior})`,
    `  template ${a.template} · model ${a.model} · effort ${a.effort} · attempts ${a.attempts} · cap $${a.budgetUsd.toFixed(2)}`,
    ...d.difficulty.reasons.map((r) => `  ${r}`),
    ...d.adjustments.map((r) => `  adjusted: ${r}`),
  ];
  if (d.action === "defer") lines.push("  action: defer (no budget left today)");
  if (d.advice !== undefined) lines.push(`  advice: ${d.advice}`);
  return lines;
}

async function decide(ctx: CommandContext, f: RouteFlags): Promise<number> {
  const req = await decideRequest(ctx, f);
  if (typeof req === "number") return req;
  if (typeof req === "string") return usageError(ctx.io, usage, req);
  const d = await routeIssue(ctx.routing(), req);
  if (!d.ok) return adapterFailure(ctx.io, "routing log", d.error);
  if (f.json) ctx.io.out(JSON.stringify(d.value));
  else for (const line of renderDecision(d.value)) ctx.io.out(line);
  return 0;
}

async function outcome(ctx: CommandContext, f: RouteFlags): Promise<number> {
  const id = f.values["--decision"];
  if (id === undefined) return usageError(ctx.io, usage, "--decision is required");
  const result = resultOf(f.values["--result"]);
  const cost = usd("--cost-usd", f.values["--cost-usd"]);
  const pr = positiveInt("--pr", f.values["--pr"]);
  for (const v of [cost, pr]) if (typeof v === "string") return usageError(ctx.io, usage, v);
  if (result !== "success" && result !== "failure") return usageError(ctx.io, usage, result);
  if (typeof cost === "number" && cost < 0)
    return usageError(ctx.io, usage, "--cost-usd must not be negative");
  const failureClass = f.values["--failure-class"];
  const o = await recordOutcome(ctx.routing(), {
    decisionId: id,
    result,
    ...(failureClass === undefined ? {} : { failureClass }),
    ...(typeof cost === "number" ? { costUsd: cost } : {}),
    ...(typeof pr === "number" ? { pr } : {}),
  });
  if (!o.ok) return adapterFailure(ctx.io, "routing log", o.error);
  if (f.json) ctx.io.out(JSON.stringify(o.value));
  else ctx.io.out(`✓ outcome ${o.value.result} recorded for ${id}`);
  return 0;
}

const pct = (n: number | null): string => (n === null ? "-" : `${Math.round(n * 100)}%`);
const dollars = (n: number | null): string => (n === null ? "-" : `$${n.toFixed(2)}`);

export function renderStats(s: RoutingStats): readonly string[] {
  return [
    `${s.runs} finished routed runs (${s.byMode.apply} applied, ${s.byMode.shadow} shadow), ${s.open} open`,
    "tier      runs  success  cost/success",
    ...s.tiers.map(
      (t) =>
        `${t.tier.padEnd(9)} ${String(t.runs).padStart(4)}  ${pct(t.successRate).padStart(7)}  ${dollars(t.costPerSuccessUsd).padStart(12)}`,
    ),
  ];
}

async function stats(ctx: CommandContext, f: RouteFlags): Promise<number> {
  const s = await loadRoutingStats(ctx.routing());
  if (!s.ok) return adapterFailure(ctx.io, "routing log", s.error);
  if (f.json) ctx.io.out(JSON.stringify(s.value));
  else for (const line of renderStats(s.value)) ctx.io.out(line);
  return 0;
}

const RUNNERS = { decide, outcome, stats } as const;

export const routeCommand: Command = {
  name: "route",
  aliases: [],
  summary: "Adaptive compute router: pick template, model, effort and attempts by issue difficulty",
  usage,
  async run(args, ctx) {
    if (isHelpRequest(args, [...SUBCOMMANDS])) {
      ctx.io.out(usage);
      return 0;
    }
    const [sub, ...rest] = args;
    if (sub === undefined) return usageError(ctx.io, usage, "a subcommand is required");
    if (!(SUBCOMMANDS as readonly string[]).includes(sub)) {
      return usageError(ctx.io, usage, `unknown subcommand: ${sub}`);
    }
    const flags = parseRouteFlags(rest, ALLOWED[sub as Sub]);
    if (typeof flags === "string") return usageError(ctx.io, usage, flags);
    return RUNNERS[sub as Sub](ctx, flags);
  },
};
