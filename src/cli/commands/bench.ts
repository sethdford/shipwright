import type { Command, CommandContext } from "../command";
import { isHelpRequest, usageError } from "../shared";
import { benchPlan, benchReport, benchRun, benchValidate } from "./bench-actions";
import { BENCH_SUBS, type BenchFlags, type BenchSub, parseBenchFlags } from "./bench-flags";
import { BenchError } from "./bench-load";
import {
  benchExportEval,
  benchExportSwebench,
  benchImportSwebench,
  benchMineHoldout,
  benchSampleSwebench,
} from "./bench-swebench";

const usage = `USAGE
  shipwright bench plan     --tasks FILE --arms FILE [--trials N] [--out DIR]
  shipwright bench run      --tasks FILE --arms FILE --out DIR --budget USD [--trials N] [--arm ID]
  shipwright bench report   --tasks FILE --arms FILE --out DIR [--k N] [--format md|html|json]
  shipwright bench validate --tasks FILE --out DIR
  shipwright bench export-eval     --out DIR --arm ID
  shipwright bench export-swebench --out DIR --arm ID [--trial N]
  shipwright bench import-swebench --out DIR --arm ID --report FILE [--trial N]
  shipwright bench sample-swebench --from FILE.jsonl --n N [--seed S] [--name NAME]
  shipwright bench mine-holdout    --repo OWNER/NAME --since DATE [--max N] [--setup "CMD"]...

DESCRIPTION
  Head-to-head benchmark (ADR-0012): runs each arm (bare Claude Code, Shipwright, or any other
  agent CLI) on the same tasks, from the same base commit, with the same model and time limit,
  and grades every run with hidden tests. Holdout tasks are graded here; SWE-bench Verified
  tasks are graded by the official harness (export-swebench, then import-swebench).

  Results go to DIR/results.jsonl (append-only; run is resumable) and DIR/patches/. run stops
  before any run the budget cannot cover, counting reported spend or the arm's estimate.
  report writes report.md, report.html and report.json: resolve rate with a 95% Wilson
  interval, pass^k, spend, $ per resolved task, and an exact sign test of each arm against
  the baseline on per-task results. sample-swebench and mine-holdout print a task manifest.

  Agents never get a GitHub token. Bare Claude Code runs under the same permission
  policy as Shipwright's agents (config/agent-permissions.json).

OPTIONS
  --trials N   Runs per task per arm, 1 to 10 (default 1)
  --k N        pass^k: runs that must all pass, 1 to 10 (default 1)
  --budget USD Hard spend cap for this results directory
  --arm ID     Only this arm

EXIT CODES
  0  done      1  failed      2  usage error      3  stopped by budget, or an unfair oracle`;

const HANDLERS: Record<BenchSub, (f: BenchFlags, c: CommandContext) => Promise<number>> = {
  plan: benchPlan,
  run: benchRun,
  report: benchReport,
  validate: benchValidate,
  "export-eval": benchExportEval,
  "export-swebench": benchExportSwebench,
  "import-swebench": benchImportSwebench,
  "sample-swebench": benchSampleSwebench,
  "mine-holdout": benchMineHoldout,
};

export const benchCommand: Command = {
  name: "bench",
  aliases: [],
  summary:
    "Head-to-head benchmark: Shipwright vs bare Claude Code and other agents, graded by hidden tests",
  usage,
  async run(args, ctx) {
    if (isHelpRequest(args, BENCH_SUBS)) {
      ctx.io.out(usage);
      return 0;
    }
    const flags = parseBenchFlags(args);
    if (typeof flags === "string") return usageError(ctx.io, usage, flags);
    try {
      return await HANDLERS[flags.sub](flags, ctx);
    } catch (e) {
      if (!(e instanceof BenchError)) throw e;
      ctx.io.err(`✗ bench: ${e.message}`);
      return 1;
    }
  },
};
