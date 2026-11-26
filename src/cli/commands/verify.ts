import { readVerifier, scoreChange, trainVerifier } from "../../contexts/quality";
import type { Command, CommandContext } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";
import { parseScoreFlags, parseTrainFlags, type ScoreFlags } from "./verify-flags";
import { renderScore, renderStored, renderTraining } from "./verify-render";

const usage = `USAGE
  shipwright verify score [--base REF] [--title T] [--body-file F] [--tests pass|fail|unknown]
                          [--cross R] [--rubric R] [--critic] [--critic-model M]
                          [--critic-budget USD] [--mode off|advisory|enforce] [--format text|json]
  shipwright verify train [--days N] [--agent N,...] [--exclude N,...] [--human-weight W]
                          [--dry-run] [--format text|json]
  shipwright verify show

DESCRIPTION
  A merge verifier: predicts whether a change will merge and stay merged (not reverted within
  14 days), before its PR is opened, and stops changes that should not become PRs.

  score  Scores the current branch against --base (git diff base...HEAD; default origin/main)
         with the trained model, or with the hand-set prior when nothing was trained. Features
         come from the diff (size, run output, plan-only changes, CI or test-config edits, tests
         added or weakened) and the title and description (model chatter). --tests, --cross and
         --rubric pass the run's own signals (test result, tournament cross-test pass rate, rubric
         score, each 0 to 1). --critic adds a prompted reviewer (LLM-as-judge) whose stated chance
         is one more feature, trusted at a third of its stated confidence until training says
         otherwise; it spends up to --critic-budget (default 0.50 USD).
  train  Learns the weights from this repository's closed PRs (read-only, through gh): labels
         them, fits a logistic model around the hand-set prior, and measures it leave-one-out
         (Brier, AUC, calibration error) against the prior. Factory PRs weigh 1; human PRs weigh
         --human-weight (default 0.5; 0 learns from factory PRs only). Dependency-bot PRs and test
         runs are left out. --agent marks older factory PRs that carry no marker. Saves to
         $SHIPWRIGHT_STATE_DIR/verifier/model.json unless --dry-run.
  show   Prints the trained weights and their evidence.

GATE (score)
  Hard stops block in enforce mode from day one: no change beyond plans or run output, failing
  tests, run output in the diff. A low predicted chance (below 20%) blocks only once the model
  is trusted: 20 or more labelled PRs, 5 of each outcome, leave-one-out AUC 0.7 or more, and a
  Brier score better than guessing the base rate. Until then it warns.
  The mode comes from --mode, else SHIPWRIGHT_VERIFIER (off, advisory, enforce; default
  advisory). Advisory never blocks and reports what enforce would do.

EXIT CODES
  0  pass or warn (score), done (train, show)   1  could not read git, GitHub or the model
  2  usage error                                 3  blocked (score, enforce mode only)`;

const SUBCOMMANDS = ["score", "train", "show"];

async function readBody(ctx: CommandContext, path: string | null): Promise<string | null> {
  if (path === null) return "";
  const r = await ctx.files().readText(path);
  if (!r.ok) {
    ctx.io.err(`✗ verify: cannot read ${path}: ${r.error.message}`);
    return null;
  }
  return r.value;
}

async function score(args: readonly string[], ctx: CommandContext): Promise<number> {
  const flags: ScoreFlags | string = parseScoreFlags(args, ctx.env.SHIPWRIGHT_VERIFIER);
  if (typeof flags === "string") return usageError(ctx.io, usage, flags);
  const body = await readBody(ctx, flags.bodyFile);
  if (body === null) return 1;
  const r = await scoreChange(ctx.verifier(), {
    baseRef: flags.base,
    title: flags.title,
    body,
    mode: flags.mode,
    signals: { ownTestsPass: flags.tests, crossPassRate: flags.cross, rubricScore: flags.rubric },
    critic: flags.critic ? { model: flags.criticModel, budgetUsd: flags.criticBudget } : null,
  });
  if (!r.ok) return adapterFailure(ctx.io, "verify", r.error);
  ctx.io.out(flags.format === "json" ? JSON.stringify(r.value, null, 2) : renderScore(r.value));
  return r.value.decision.verdict === "block" ? 3 : 0;
}

async function train(args: readonly string[], ctx: CommandContext): Promise<number> {
  const flags = parseTrainFlags(args);
  if (typeof flags === "string") return usageError(ctx.io, usage, flags);
  const r = await trainVerifier(ctx.verifier(), flags);
  if (!r.ok) return adapterFailure(ctx.io, "verify", r.error);
  ctx.io.out(flags.format === "json" ? JSON.stringify(r.value, null, 2) : renderTraining(r.value));
  return 0;
}

async function show(args: readonly string[], ctx: CommandContext): Promise<number> {
  if (args.length > 0) return usageError(ctx.io, usage, `unknown option: ${args[0]}`);
  const r = await readVerifier(ctx.verifier());
  if (!r.ok) return adapterFailure(ctx.io, "verify", r.error);
  ctx.io.out(renderStored(r.value));
  return 0;
}

export const verifyCommand: Command = {
  name: "verify",
  aliases: [],
  summary: "Merge verifier: predict whether a change will merge, and gate PRs on it",
  usage,
  async run(args, ctx) {
    if (isHelpRequest(args, SUBCOMMANDS)) {
      ctx.io.out(usage);
      return 0;
    }
    const [sub, ...rest] = args;
    if (sub === "score") return score(rest, ctx);
    if (sub === "train") return train(rest, ctx);
    if (sub === "show") return show(rest, ctx);
    return usageError(ctx.io, usage, sub ? `unknown subcommand: ${sub}` : "missing subcommand");
  },
};
