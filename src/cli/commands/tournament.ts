import { runTournament } from "../../contexts/delivery";
import type { Command } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";
import { parseTournamentFlags } from "./tournament-flags";
import { renderTournamentMarkdown, renderTournamentText } from "./tournament-render";

const usage = `USAGE
  shipwright tournament --goal-file F --test-cmd CMD [options]

DESCRIPTION
  Tournament mode for the build stage: N independent attempts at the same task, each in its own git
  worktree with a different opening strategy, then one winner chosen in four steps:
    1. Gate: the patch is not empty and the repository's tests (--test-cmd) pass on it.
    2. Cross-tests: every attempt's new tests run against every other attempt's patch.
    3. Rubric: a rubric drafted from the task (plus Shipwright's fixed test-integrity criteria)
       is graded against each diff.
    4. Judge: when several candidates are close, a blind group-wise judge challenges what they all
       assume and picks one.
  The winner is fast-forwarded onto the current branch (unless --no-adopt). Nothing is pushed.
  Worktrees live under the state directory and are always removed. The goal file is task text and
  is passed to agents only as data. --test-cmd and --setup-cmd are operator configuration, run with
  bash in each worktree without GitHub tokens in the environment.

OPTIONS
  --goal-file F          The task (issue text and pipeline context). Required.
  --test-cmd CMD         The repository's test command. Required.
  --setup-cmd CMD        Run once in each new worktree first (for example "bun install").
  --attempts N           1 to 5 (default 3)
  --budget-usd X         Total model spend cap for the tournament (default 15)
  --model M              Builder model (default opus)
  --judge-model M        Rubric, grading and judge model (default: the builder model)
  --max-turns N          Builder turn cap per attempt (default 60)
  --build-timeout-min N  Per attempt (default 45)
  --test-timeout-min N   Per test run (default 15)
  --no-adopt             Report the winner without touching the current branch
  --adaptive MODE        Early stop once an attempt is clearly good enough (needs the merge
                         verifier): off; shadow (default: run every attempt, report where it would
                         have stopped and what that would have saved); enforce (attempts run one at
                         a time and stop at the first one the verifier scores at --stop-at or
                         above; only when the verifier reports itself ready, otherwise shadow)
  --stop-at X            Early-stop threshold, the verifier's probability, 0.5 to 0.99 (default 0.8)
  --format F             text (default), json, or markdown (a section for the PR body)

EXIT CODES
  0  a winner was chosen (and adopted, unless --no-adopt)
  1  could not start (no git repository, unreadable goal file) or could not adopt the winner
  2  usage error
  3  no attempt was good enough`;

export const tournamentCommand: Command = {
  name: "tournament",
  aliases: [],
  summary: "Build stage tournament: parallel attempts, cross-tests, rubric and a blind judge",
  usage,
  async run(args, ctx) {
    const { io } = ctx;
    if (isHelpRequest(args)) {
      io.out(usage);
      return 0;
    }
    const flags = parseTournamentFlags(args);
    if (typeof flags === "string") return usageError(io, usage, flags);
    const goal = await ctx.files().readText(flags.goalFile);
    if (!goal.ok) return adapterFailure(io, "tournament goal file", goal.error);
    if (goal.value.trim() === "") return usageError(io, usage, "the goal file is empty");
    const r = await runTournament(ctx.delivery(), { ...flags.request, goal: goal.value });
    if (!r.ok) return adapterFailure(io, "tournament", r.error);
    const report = r.value;
    if (flags.format === "json") io.out(JSON.stringify(report, null, 2));
    else if (flags.format === "markdown") io.out(renderTournamentMarkdown(report));
    else io.out(renderTournamentText(report));
    for (const note of report.notes) io.err(`⚠ tournament: ${note}`);
    if (report.selection.winner === null) return 3;
    return flags.request.adopt && !report.adopted ? 1 : 0;
  },
};
