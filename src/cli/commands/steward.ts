import {
  DEFAULT_LIMITS,
  DEFAULT_REVIEW_BOTS,
  inspectPull,
  offeredComments,
  parseHistory,
  postReplies,
  pushFix,
  rerunJobs,
  scanChange,
} from "../../contexts/delivery";
import type { Command, CommandContext } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";
import { botList, intIn, jobIds, parseStewardFlags, prNumber } from "./steward-flags";
import { renderReport, renderScan } from "./steward-render";

const usage = `USAGE
  shipwright steward inspect --pr N [--history FILE] [--max-rounds N] [--bots a[bot],b[bot]]
                             [--no-checks-ok yes|no] [--format text|json]
  shipwright steward reply   --pr N --sha SHA --report FILE --changed yes|no [--replies FILE]
                             [--format text|json]
  shipwright steward rerun   --pr N --jobs ID,ID
  shipwright steward push    --pr N --branch B --sha SHA --from SHA [--repo-dir DIR]
  shipwright steward scan    [--base REF] [--format text|json]

DESCRIPTION
  The PR steward (ADR-0017) keeps a pipeline PR moving after it opens: it fixes failing CI and
  answers review comments, a bounded number of rounds, until the PR is green. The bash pipeline
  stage "steward" drives it; each subcommand is one step.

  inspect  Reads the PR (checks, failed job logs, review comments) and decides the next action:
           fix, rerun, wait, done or stop. Failures are triaged as code (fix), infra (re-run once)
           or baseline (also failing on the base commit: not this PR's fault). Only comments from
           OWNER, MEMBER or COLLABORATOR authors and the listed review bots count; the steward's own
           replies and comments it has answered do not. A commit with no checks is "wait" unless
           --no-checks-ok yes (the caller waited long enough: the PR has no CI). For fix, the report carries the brief:
           trusted instructions plus untrusted items the caller wraps as data.
  reply    Posts the fix round's replies: each inline comment in its thread, the rest in one PR
           comment. --report is that round's inspect JSON (which comments were offered); --replies
           is the fixer's report file; --changed (required) is no when the round committed nothing ("fixed" is
           then posted as no change). Notes are cleaned: no HTML, links, images or hidden
           characters, mentions and #-references defused, and a note that looks like it holds a
           credential is withheld. Prints which comments got a reply and which did not.
  rerun    Re-runs the given Actions jobs (skips jobs already running).
  push     Fast-forwards the PR branch on origin to SHA, the round's commit on top of --from, the
           PR head the round started from. Refuses unless the branch is the PR's own head branch
           in this repository, the PR is still at --from, and the round's change passes the scan
           (no secret, focused test, conflict marker or debugger statement). Never a force push;
           hooks are off.
  scan     The pre-PR self-scan of the lines this branch adds (default base origin/main): secrets
           block, conflict markers, focused tests and debugger statements need a fix, skipped tests
           and console.log are notes.

EXIT CODES
  0  done (scan: pass)   1  could not read or write GitHub or git   2  usage error
  3  scan: blocked (a secret)   4  scan: needs a fix`;

const ALLOWED: Readonly<Record<string, readonly string[]>> = {
  inspect: ["--pr", "--history", "--max-rounds", "--bots", "--no-checks-ok", "--format"],
  reply: ["--pr", "--sha", "--report", "--replies", "--changed", "--format"],
  rerun: ["--pr", "--jobs"],
  push: ["--pr", "--branch", "--sha", "--from", "--repo-dir"],
  scan: ["--base", "--format"],
};
const SUBCOMMANDS = Object.keys(ALLOWED);

async function readOptional(ctx: CommandContext, path: string | undefined): Promise<string | null> {
  if (path === undefined) return "";
  const r = await ctx.files().readText(path);
  return r.ok ? r.value : r.error.kind === "not_found" ? "" : null;
}

async function inspect(args: readonly string[], ctx: CommandContext): Promise<number> {
  const f = parseStewardFlags(args, ALLOWED.inspect ?? []);
  if (typeof f === "string") return usageError(ctx.io, usage, f);
  const pr = prNumber(f.values["--pr"]);
  const maxRounds = intIn("--max-rounds", f.values["--max-rounds"], DEFAULT_LIMITS.maxRounds, 20);
  const bots = botList(f.values["--bots"] ?? ctx.env.SHIPWRIGHT_STEWARD_BOTS, DEFAULT_REVIEW_BOTS);
  for (const v of [pr, maxRounds, bots])
    if (typeof v === "string") return usageError(ctx.io, usage, v);
  const noChecks = f.values["--no-checks-ok"] ?? "no";
  if (noChecks !== "yes" && noChecks !== "no")
    return usageError(ctx.io, usage, "--no-checks-ok must be yes or no");
  const history = await readOptional(ctx, f.values["--history"]);
  if (history === null) return usageError(ctx.io, usage, `cannot read ${f.values["--history"]}`);
  const r = await inspectPull(ctx.steward(), {
    pr: pr as number,
    history: parseHistory(history),
    limits: { ...DEFAULT_LIMITS, maxRounds: maxRounds as number },
    bots: bots as Set<string>,
    noChecksOk: noChecks === "yes",
  });
  if (!r.ok) return adapterFailure(ctx.io, "steward", r.error);
  ctx.io.out(f.json ? JSON.stringify(r.value, null, 2) : renderReport(r.value));
  return 0;
}

async function reply(args: readonly string[], ctx: CommandContext): Promise<number> {
  const f = parseStewardFlags(args, ALLOWED.reply ?? []);
  if (typeof f === "string") return usageError(ctx.io, usage, f);
  const pr = prNumber(f.values["--pr"]);
  if (typeof pr === "string") return usageError(ctx.io, usage, pr);
  const sha = f.values["--sha"] ?? "";
  if (!/^[0-9a-f]{40}$/.test(sha))
    return usageError(ctx.io, usage, "--sha must be a full commit sha");
  const report = await readOptional(ctx, f.values["--report"]);
  if (!report) return usageError(ctx.io, usage, "--report must name the round's inspect JSON");
  const offered = offeredComments(report);
  if (typeof offered === "string") return usageError(ctx.io, usage, offered);
  const replies = await readOptional(ctx, f.values["--replies"]);
  // Required: a default of "yes" would post "Fixed in …" for a round that committed nothing.
  const changed = f.values["--changed"];
  if (changed !== "yes" && changed !== "no")
    return usageError(ctx.io, usage, "--changed yes|no is required");
  const r = await postReplies(ctx.steward(), {
    pr,
    sha,
    offered,
    repliesText: replies ?? "",
    changed: changed === "yes",
  });
  if (!r.ok) return adapterFailure(ctx.io, "steward", r.error);
  const text = `replied to ${r.value.replied.length}; unhandled: ${r.value.unhandled.join(",") || "none"}`;
  ctx.io.out(f.json ? JSON.stringify(r.value) : text);
  return 0;
}

async function rerun(args: readonly string[], ctx: CommandContext): Promise<number> {
  const f = parseStewardFlags(args, ALLOWED.rerun ?? []);
  if (typeof f === "string") return usageError(ctx.io, usage, f);
  const pr = prNumber(f.values["--pr"]);
  const jobs = jobIds(f.values["--jobs"]);
  for (const v of [pr, jobs]) if (typeof v === "string") return usageError(ctx.io, usage, v);
  const r = await rerunJobs(ctx.steward(), pr as number, jobs as number[]);
  if (!r.ok) return adapterFailure(ctx.io, "steward", r.error);
  ctx.io.out(`re-ran ${r.value.length} job(s)`);
  return 0;
}

async function push(args: readonly string[], ctx: CommandContext): Promise<number> {
  const f = parseStewardFlags(args, ALLOWED.push ?? []);
  if (typeof f === "string") return usageError(ctx.io, usage, f);
  const pr = prNumber(f.values["--pr"]);
  if (typeof pr === "string") return usageError(ctx.io, usage, pr);
  const branch = f.values["--branch"];
  const sha = f.values["--sha"];
  const from = f.values["--from"];
  if (!branch || !sha || !from) {
    return usageError(ctx.io, usage, "--branch, --sha and --from are required");
  }
  const r = await pushFix(ctx.steward(), {
    pr,
    repoDir: f.values["--repo-dir"] ?? ".",
    branch,
    sha,
    from,
  });
  if (!r.ok) return adapterFailure(ctx.io, "steward", r.error);
  ctx.io.out(
    r.value === "done"
      ? `pushed ${sha.slice(0, 12)} to ${branch}`
      : `${branch} is already at ${sha.slice(0, 12)}`,
  );
  return 0;
}

async function scan(args: readonly string[], ctx: CommandContext): Promise<number> {
  const f = parseStewardFlags(args, ALLOWED.scan ?? []);
  if (typeof f === "string") return usageError(ctx.io, usage, f);
  const r = await scanChange(ctx.steward().change, f.values["--base"] ?? "origin/main");
  if (!r.ok) return adapterFailure(ctx.io, "steward", r.error);
  ctx.io.out(f.json ? JSON.stringify(r.value, null, 2) : renderScan(r.value));
  return r.value.verdict === "block" ? 3 : r.value.verdict === "fix" ? 4 : 0;
}

const RUNNERS: Readonly<
  Record<string, (args: readonly string[], ctx: CommandContext) => Promise<number>>
> = {
  inspect,
  reply,
  rerun,
  push,
  scan,
};

export const stewardCommand: Command = {
  name: "steward",
  aliases: [],
  summary: "PR steward: fix failing CI and answer review comments after a PR opens",
  usage,
  async run(args, ctx) {
    if (isHelpRequest(args, SUBCOMMANDS)) {
      ctx.io.out(usage);
      return 0;
    }
    const [sub, ...rest] = args;
    const runner = sub === undefined ? undefined : RUNNERS[sub];
    if (!runner)
      return usageError(ctx.io, usage, sub ? `unknown subcommand: ${sub}` : "missing subcommand");
    return runner(rest, ctx);
  },
};
