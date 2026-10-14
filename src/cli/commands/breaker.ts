import {
  type BreakerReport,
  breakerStatus,
  checkBreaker,
  describeBreaker,
} from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";

const usage = `USAGE
  shipwright breaker <status|check> [--json]

DESCRIPTION
  Global circuit breaker over recent pipeline runs (spec §6.2, ADR-0007). It opens when at
  least 5 of the last 8 finished runs failed. After a 30-minute cool-down one probe run is
  allowed; its result closes or re-opens the breaker.

COMMANDS
  status   Print the breaker state. Never writes. Exits 0, or 1 if the run history cannot be
           read.
  check    Exit 0 when dispatch is allowed, 1 when it is not or the run history cannot be
           read. While open, opens or updates the one shipwright:incident issue (once per trip).

OPTIONS
  --json   Print one JSON object: state, allowed, and since, probeAfter, incident,
           incidentError or error when they apply. Exit codes are unchanged.

NOTES
  Both commands read GitHub Actions. Without GitHub (--no-github / NO_GITHUB) the standalone
  check fails closed (exit 1); \`shipwright gates check\` skips the breaker instead.

EXAMPLES
  shipwright breaker status
  shipwright breaker check && gh workflow run shipwright-pipeline.yml -f issue_number=42`;

function reportJson(report: BreakerReport) {
  const { state } = report;
  return {
    state: state.kind,
    allowed: report.allowed,
    ...(state.kind === "open" ? { since: state.since, probeAfter: state.probeAfter } : {}),
    ...(state.kind === "half_open" ? { since: state.since } : {}),
    ...(report.incident ? { incident: report.incident } : {}),
    ...(report.incidentError ? { incidentError: report.incidentError } : {}),
  };
}

const errorJson = (message: string) => ({ state: "unknown", allowed: false, error: message });

export const breakerCommand: Command = {
  name: "breaker",
  aliases: [],
  summary: "Global circuit breaker: show it, or check it as a dispatch gate",
  usage,
  async run(args, { io, safety }) {
    if (isHelpRequest(args, ["status", "check"])) {
      io.out(usage);
      return 0;
    }
    const json = args.includes("--json");
    const [sub, ...rest] = args.filter((a) => a !== "--json");
    if ((sub !== "status" && sub !== "check") || rest.length > 0) {
      return usageError(io, usage, `Expected status or check, got: ${args.join(" ") || "nothing"}`);
    }
    const r = sub === "check" ? await checkBreaker(safety()) : await breakerStatus(safety());
    if (json) {
      io.out(JSON.stringify(r.ok ? reportJson(r.value) : errorJson(r.error.message)));
    } else if (!r.ok) {
      return adapterFailure(io, "breaker", r.error);
    } else {
      io.out(`${r.value.allowed ? "✓" : "✗"} breaker: ${describeBreaker(r.value.state)}`);
      if (r.value.incident) {
        io.out(`  incident #${r.value.incident.issue} (${r.value.incident.action})`);
      }
      if (r.value.incidentError) io.err(`  ✗ incident not recorded: ${r.value.incidentError}`);
    }
    if (!r.ok) return 1;
    return sub === "check" && !r.value.allowed ? 1 : 0;
  },
};
