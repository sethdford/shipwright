import {
  type IntegrityMode,
  lockTests,
  materialize,
  type RunTemplate,
  verifyGreen,
  verifyRed,
} from "../../contexts/planning";
import type { Command, CommandContext } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";
import { renderGreen, renderMaterialized, renderRed } from "./acceptance-render";

const SUBCOMMANDS = ["materialize", "verify-red", "lock", "verify-green"] as const;
type Sub = (typeof SUBCOMMANDS)[number];

const usage = `USAGE
  shipwright acceptance materialize  --answer FILE --manifest FILE [--root DIR]
  shipwright acceptance verify-red   --manifest FILE [--test-cmd CMD] [--command JSON] [--timeout SEC] [--root DIR] [--json]
  shipwright acceptance lock         --manifest FILE --lock FILE [--test-cmd CMD] [--command JSON] [--root DIR]
  shipwright acceptance verify-green --lock FILE [--integrity enforce|warn] [--timeout SEC] [--root DIR] [--json]

DESCRIPTION
  Spec-first acceptance tests (ADR-0012). Before any implementation, each issue becomes numbered
  acceptance criteria (AC-1, AC-2, ...) and new test files that check them.

  materialize   Writes the test writer's answer (fenced blocks: acceptance.json plus one per test file).
                All or nothing: paths must be new test files inside the repository, every criterion
                needs a test, and every test must name the criteria it claims.
  verify-red    Runs each test file alone and requires it to fail for the right reason: an assertion
                or the missing feature, not a syntax error, a missing framework, no tests or a pass.
  lock          Records the commit that holds the proven-red tests and each file's blob id.
  verify-green  The build gate: flags test tampering since the lock (edited acceptance tests, deleted
                tests, skip/only markers, dropped assertions, narrowed test collection), restores the
                locked tests exactly, and requires every one to pass.

OPTIONS
  --test-cmd CMD   The project's test command; a per-file command is derived from it when its shape is
                   known (bun test, vitest, jest, pytest, go test, cargo test, npm test, ...).
  --command JSON   A configured per-file argv, e.g. '["bun","test","{file}"]' ({file} {dir} {stem}).
  --integrity      enforce (default): a blocking finding fails the gate. warn: report only.
  --timeout SEC    Per test file (default 300).

EXIT CODES
  0  passed      1  failed or could not verify (fails closed)      2  usage error`;

type Flags = Readonly<Record<string, string>>;

const ALLOWED: Readonly<Record<Sub, readonly string[]>> = {
  materialize: ["--answer", "--manifest", "--root"],
  "verify-red": ["--manifest", "--test-cmd", "--command", "--timeout", "--root", "--json"],
  lock: ["--manifest", "--lock", "--test-cmd", "--command", "--root"],
  "verify-green": ["--lock", "--integrity", "--timeout", "--root", "--json"],
};
const REQUIRED: Readonly<Record<Sub, readonly string[]>> = {
  materialize: ["--answer", "--manifest"],
  "verify-red": ["--manifest"],
  lock: ["--manifest", "--lock"],
  "verify-green": ["--lock"],
};

/** Flags for one subcommand, or an error message. `--json` takes no value. */
export function parseFlags(sub: Sub, args: readonly string[]): Flags | string {
  const flags: Record<string, string> = {};
  for (let i = 0; i < args.length; i++) {
    const a = args[i] ?? "";
    if (!ALLOWED[sub].includes(a)) return `unknown option for ${sub}: ${a}`;
    if (a in flags) return `${a} given twice`;
    if (a === "--json") {
      flags[a] = "1";
      continue;
    }
    const v = args[++i];
    if (v === undefined || v.length === 0) return `${a} needs a value`;
    flags[a] = v;
  }
  const missing = REQUIRED[sub].filter((r) => !(r in flags));
  if (missing.length > 0) return `missing ${missing.join(", ")}`;
  return flags;
}

export function parseTemplate(json: string | undefined): RunTemplate | undefined | string {
  if (json === undefined) return undefined;
  try {
    const v: unknown = JSON.parse(json);
    if (Array.isArray(v) && v.length > 0 && v.every((x) => typeof x === "string")) return v;
  } catch {
    // fall through
  }
  return "--command must be a JSON array of strings";
}

function timeoutMs(flags: Flags): number | string {
  const raw = flags["--timeout"] ?? "300";
  if (!/^[1-9]\d{0,4}$/.test(raw)) return "--timeout must be whole seconds (1-99999)";
  return Number(raw) * 1000;
}

async function runMaterialize(flags: Flags, ctx: CommandContext): Promise<number> {
  const answer = await ctx.files().readText(flags["--answer"] ?? "");
  if (!answer.ok) return adapterFailure(ctx.io, "answer", answer.error);
  const m = await materialize(
    answer.value,
    flags["--manifest"] ?? "",
    ctx.acceptance(flags["--root"]),
  );
  renderMaterialized(ctx.io, m);
  return m.ok ? 0 : 1;
}

async function runGreen(flags: Flags, ms: number, ctx: CommandContext): Promise<number | string> {
  const integrity = flags["--integrity"] ?? "enforce";
  if (integrity !== "enforce" && integrity !== "warn") return "--integrity must be enforce or warn";
  const r = await verifyGreen(
    { lockPath: flags["--lock"] ?? "", timeoutMs: ms, integrity: integrity as IntegrityMode },
    ctx.acceptance(flags["--root"]),
  );
  flags["--json"] ? ctx.io.out(JSON.stringify(r)) : renderGreen(ctx.io, r);
  return r.ok ? 0 : 1;
}

async function runSub(sub: Sub, flags: Flags, ctx: CommandContext): Promise<number | string> {
  if (sub === "materialize") return runMaterialize(flags, ctx);
  const ms = timeoutMs(flags);
  if (typeof ms === "string") return ms;
  if (sub === "verify-green") return runGreen(flags, ms, ctx);
  const configured = parseTemplate(flags["--command"]);
  if (typeof configured === "string") return configured;
  const opts = {
    manifestPath: flags["--manifest"] ?? "",
    configured,
    testCmd: flags["--test-cmd"],
    timeoutMs: ms,
  };
  const ports = ctx.acceptance(flags["--root"]);
  if (sub === "verify-red") {
    const r = await verifyRed(opts, ports);
    flags["--json"] ? ctx.io.out(JSON.stringify(r)) : renderRed(ctx.io, r);
    return r.ok ? 0 : 1;
  }
  const r = await lockTests({ ...opts, lockPath: flags["--lock"] ?? "" }, ports);
  if (!r.ok) for (const p of r.problems) ctx.io.out(`✗ ${p}`);
  else
    ctx.io.out(
      `✓ locked ${r.lock.tests.length} acceptance test(s) at ${r.lock.commit.slice(0, 12)}`,
    );
  return r.ok ? 0 : 1;
}

export const acceptanceCommand: Command = {
  name: "acceptance",
  aliases: [],
  summary: "Spec-first acceptance tests: write, prove red, lock, gate the build on them",
  usage,
  async run(args, ctx) {
    if (args.length === 0 || isHelpRequest(args, SUBCOMMANDS)) {
      ctx.io.out(usage);
      return args.length === 0 ? 2 : 0;
    }
    const [sub, ...rest] = args;
    if (!SUBCOMMANDS.includes(sub as Sub))
      return usageError(ctx.io, usage, `unknown subcommand: ${sub}`);
    const flags = parseFlags(sub as Sub, rest);
    if (typeof flags === "string") return usageError(ctx.io, usage, flags);
    const code = await runSub(sub as Sub, flags, ctx);
    return typeof code === "string" ? usageError(ctx.io, usage, code) : code;
  },
};
