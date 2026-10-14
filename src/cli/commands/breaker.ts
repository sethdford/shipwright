import { breakerStatus, checkBreaker, describeBreaker } from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, isHelp, usageError } from "../shared";

const usage = `USAGE
  shipwright breaker <status|check>

DESCRIPTION
  Global circuit breaker over recent pipeline runs (spec §6.2, ADR-0007). It opens when at
  least 5 of the last 8 finished runs failed. After a 30-minute cool-down one probe run is
  allowed; its result closes or re-opens the breaker.

COMMANDS
  status   Print the breaker state. Never writes. Exits 0.
  check    Exit 0 when dispatch is allowed, 1 when it is not or the run history cannot be
           read. While open, opens or updates the one shipwright:incident issue (once per trip).

EXAMPLES
  shipwright breaker status
  shipwright breaker check && gh workflow run shipwright-pipeline.yml -f issue_number=42`;

export const breakerCommand: Command = {
  name: "breaker",
  aliases: [],
  summary: "Global circuit breaker: show it, or check it as a dispatch gate",
  usage,
  async run(args, { io, safety }) {
    const [sub, ...rest] = args;
    if (isHelp(sub)) {
      io.out(usage);
      return 0;
    }
    if ((sub !== "status" && sub !== "check") || rest.length > 0) {
      return usageError(io, usage, `Expected status or check, got: ${args.join(" ") || "nothing"}`);
    }
    const r = sub === "check" ? await checkBreaker(safety()) : await breakerStatus(safety());
    if (!r.ok) return adapterFailure(io, "breaker", r.error);
    io.out(`${r.value.allowed ? "✓" : "✗"} breaker: ${describeBreaker(r.value.state)}`);
    if (r.value.incident) {
      io.out(`  incident #${r.value.incident.issue} (${r.value.incident.action})`);
    }
    return sub === "check" && !r.value.allowed ? 1 : 0;
  },
};
