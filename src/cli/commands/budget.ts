import { checkBudget, describeBudget } from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";

const usage = `USAGE
  shipwright budget <status|check> [--estimate USD]

DESCRIPTION
  Pre-dispatch budget guard (spec §6.2, ADR-0007). Reads the daily cap and today's spend (UTC)
  from ~/.shipwright/budget.json and costs.json, written by \`shipwright cost\`.
  It blocks at exactly the cap (spend + estimate >= cap), which is stricter than \`shipwright cost\`
  (blocks only above it). Any file that exists but is malformed, and a full 1000-entry ledger that
  starts today (spend unknown), also block.
  When neither file exists (as on a CI runner) there is nothing to check: the command exits 0 and
  prints "no cost data ... budget not enforced". A CI budget source is deferred to Wave 1b/1c.
  A mis-set HOME also shows "no cost data", because the files are read from $HOME/.shipwright.

COMMANDS
  status   Print today's spend against the cap. Exits 0 unless the files cannot be read.
  check    Exit 0 when today's spend plus the estimate stays under the cap, 1 when it does not
           or the files cannot be read. No cap configured means unlimited.

OPTIONS
  --estimate USD   Expected cost of the next run (default 0)

EXAMPLES
  shipwright budget check --estimate 2.50`;

/** The --estimate value, 0 when absent, or null when malformed. */
function parseEstimate(rest: readonly string[]): number | null {
  if (rest.length === 0) return 0;
  if (rest.length !== 2 || rest[0] !== "--estimate") return null;
  const n = Number(rest[1]);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

export const budgetCommand: Command = {
  name: "budget",
  aliases: [],
  summary: "Daily budget guard: show it, or check it as a dispatch gate",
  usage,
  async run(args, { io, safety }) {
    const [sub, ...rest] = args;
    if (isHelpRequest(args, ["status", "check"])) {
      io.out(usage);
      return 0;
    }
    const estimate = parseEstimate(rest);
    if ((sub !== "status" && sub !== "check") || estimate === null) {
      return usageError(
        io,
        usage,
        `Expected status or check [--estimate USD], got: ${args.join(" ") || "nothing"}`,
      );
    }
    const r = await checkBudget(safety(), estimate);
    if (!r.ok) return adapterFailure(io, "budget", r.error);
    const mark = r.value.noData ? "⚠" : r.value.allowed ? "✓" : "✗";
    io.out(`${mark} budget: ${describeBudget(r.value)}`);
    return sub === "check" && !r.value.allowed ? 1 : 0;
  },
};
