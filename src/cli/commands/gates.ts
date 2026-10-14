import {
  checkDispatchGates,
  GATE_ORDER,
  type GateOptions,
  type GateResult,
  type GatesReport,
} from "../../contexts/orchestration";
import type { CliIO, Command } from "../command";
import { isHelp, usageError } from "../shared";

const usage = `USAGE
  shipwright gates check --retry N [--no-github] [--json]

DESCRIPTION
  Every dispatch gate in order (ADR-0007): pause, breaker, budget, review WIP, fix loop.
  Stops at the first closed gate, so a paused system never opens a breaker incident.
  A gate: exit 0 only when every gate allows dispatch. Exits 1 when a gate blocks, when any
  source cannot be read or judged (fail closed), or on an unexpected error. Exits 2 on bad
  arguments, including a missing --retry. The bash daemon and workflows call this before
  dispatching.

OPTIONS
  --retry N      Required. How many times this issue has already been retried: 0 for a first
                 dispatch. The fix-loop cap allows the first run plus 3 retries. The daemon
                 passes its retry count; auto-retry passes the number of its bot markers on
                 the issue. There is no default: an unknown count must not read as "first".
  --no-github    Skip the breaker and review-WIP gates and check only the local pause flag
                 (not the shipwright:pause label). Also set by NO_GITHUB=true.
  --json         Print one JSON object: allowed, and each gate's verdict (allowed, blocked,
                 error, skipped or not_checked) and detail. Exit codes are unchanged.

NOTES
  Without cost files (a CI runner) the budget gate passes with a ⚠ warning: nothing is enforced.

EXAMPLES
  shipwright gates check --retry 0
  shipwright gates check --retry 2 --json`;

export interface GateArgs extends GateOptions {
  readonly json: boolean;
}

/** Options from the arguments after `check`, or null when malformed or --retry is missing. */
export function parseGateArgs(args: readonly string[]): GateArgs | null {
  let github = true;
  let json = false;
  let retry: number | null = null;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const value = args[i + 1] ?? "";
    if (arg === "--no-github" && github) {
      github = false;
    } else if (arg === "--json" && !json) {
      json = true;
    } else if (arg === "--retry" && retry === null && /^(0|[1-9]\d{0,8})$/.test(value)) {
      retry = Number(value);
      i++;
    } else {
      return null;
    }
  }
  return retry === null ? null : { github, retry, json };
}

const marks: Record<GateResult["verdict"], string> = {
  allowed: "✓",
  blocked: "✗",
  error: "✗",
  skipped: "-",
};

function renderText(io: CliIO, report: GatesReport): void {
  for (const g of report.results) {
    io.out(`${g.warning ? "⚠" : marks[g.verdict]} ${g.gate}: ${g.detail}`);
  }
}

function renderJson(io: CliIO, report: GatesReport, options: GateArgs): void {
  const gates = GATE_ORDER.map(
    (gate) => report.results.find((r) => r.gate === gate) ?? { gate, verdict: "not_checked" },
  );
  io.out(
    JSON.stringify({
      allowed: report.allowed,
      retry: options.retry,
      github: options.github,
      gates,
    }),
  );
}

export const gatesCommand: Command = {
  name: "gates",
  aliases: [],
  summary: "All dispatch gates (pause, breaker, budget, review WIP, fix loop)",
  usage,
  async run(args, { io, safety, env }) {
    const [sub, ...rest] = args;
    if (args.some(isHelp)) {
      io.out(usage);
      return 0;
    }
    const parsed = parseGateArgs(rest);
    if (sub !== "check" || parsed === null) {
      const got = args.join(" ") || "nothing";
      return usageError(io, usage, `Expected check --retry N [--no-github] [--json], got: ${got}`);
    }
    const options = { ...parsed, github: parsed.github && env.NO_GITHUB !== "true" };
    try {
      const report = await checkDispatchGates(safety(), options);
      if (options.json) renderJson(io, report, options);
      else renderText(io, report);
      return report.allowed ? 0 : 1;
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      if (options.json) io.out(JSON.stringify({ allowed: false, error: message }));
      io.err(`✗ gates: cannot verify: ${message}`);
      return 1;
    }
  },
};
