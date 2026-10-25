import { type Attempt, classifyAndDecide, parseAttempts } from "../../contexts/learning";
import type { AgentFailureKind } from "../../shared/kernel/ports";
import type { Command, CommandContext } from "../command";

const KINDS: readonly string[] = [
  "refusal",
  "max_turns",
  "budget",
  "schema",
  "truncated",
  "timeout",
  "aborted",
  "transient",
  "auth",
  "execution",
];

const usage = `USAGE
  shipwright failure classify --log FILE [--kind KIND] [--attempts FILE] [--json]

DESCRIPTION
  Classifies one failed run from its log (and an optional typed agent kind) and decides retry or
  escalate. Pure: it writes nothing. Auth and invalid-input failures always escalate; an environment
  failure is retried once. --attempts is a JSON array of {cls, fingerprint} from earlier runs.

EXIT CODES
  0  retry      3  escalate      1  could not read or decide (fails closed)      2  usage error`;

interface Flags {
  readonly log: string;
  readonly kind?: string;
  readonly attempts?: string;
  readonly json: boolean;
}

function parseFlags(args: readonly string[]): Flags | string {
  let log: string | undefined;
  let kind: string | undefined;
  let attempts: string | undefined;
  let json = false;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--json") {
      json = true;
    } else if (arg === "--log" || arg === "--kind" || arg === "--attempts") {
      const value = args[i + 1];
      if (value === undefined || value.startsWith("--")) return `${arg} needs a value`;
      if (arg === "--log") log = value;
      else if (arg === "--kind") kind = value;
      else attempts = value;
      i++;
    } else {
      return `unknown option: ${arg}`;
    }
  }
  if (log === undefined) return "--log is required";
  return {
    log,
    json,
    ...(kind === undefined ? {} : { kind }),
    ...(attempts === undefined ? {} : { attempts }),
  };
}

async function readAttempts(
  ctx: CommandContext,
  path: string,
): Promise<readonly Attempt[] | string> {
  const raw = await ctx.files().readText(path);
  if (!raw.ok) return `cannot read attempts: ${raw.error.message}`;
  let json: unknown;
  try {
    json = JSON.parse(raw.value);
  } catch {
    return "--attempts is not JSON";
  }
  const checked = parseAttempts(json);
  return checked.ok ? checked.attempts : checked.reason;
}

async function classify(args: readonly string[], ctx: CommandContext): Promise<number> {
  const flags = parseFlags(args);
  if (typeof flags === "string") {
    ctx.io.err(`✗ ${flags}`);
    ctx.io.out(usage);
    return 2;
  }
  if (flags.kind !== undefined && !KINDS.includes(flags.kind)) {
    ctx.io.err(`✗ unknown --kind: ${flags.kind}`);
    return 2;
  }
  const log = await ctx.files().readText(flags.log);
  if (!log.ok) {
    ctx.io.err(`✗ cannot read log: ${log.error.message}`);
    return 1;
  }
  const attempts = flags.attempts === undefined ? [] : await readAttempts(ctx, flags.attempts);
  if (typeof attempts === "string") {
    ctx.io.err(`✗ ${attempts}`);
    return 1;
  }
  const result = classifyAndDecide({
    ...(flags.kind === undefined ? {} : { kind: flags.kind as AgentFailureKind }),
    text: log.value,
    attempts,
  });
  const line = {
    class: result.class,
    fingerprint: result.fingerprint,
    action: result.decision.action,
    reason: result.decision.reason,
  };
  ctx.io.out(flags.json ? JSON.stringify(line) : `${line.action}: ${line.class} (${line.reason})`);
  return line.action === "retry" ? 0 : 3;
}

export const failureCommand: Command = {
  name: "failure",
  aliases: [],
  summary: "Classify a failed run and decide retry or escalate (ADR-0009)",
  usage,
  async run(args, ctx) {
    const [sub, ...rest] = args;
    if (sub === undefined || sub === "--help" || sub === "-h") {
      ctx.io.out(usage);
      return sub === undefined ? 2 : 0;
    }
    if (sub !== "classify") {
      ctx.io.err(`✗ unknown subcommand: ${sub}`);
      ctx.io.out(usage);
      return 2;
    }
    return classify(rest, ctx);
  },
};
