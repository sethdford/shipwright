import type { CliIO, Command, CommandContext } from "../command";
import { isHelpRequest, usageError } from "../shared";
import {
  hydrateAction,
  initAction,
  keyAction,
  listAction,
  servicesAction,
  showAction,
} from "./env-actions";
import { type EnvFlags, parseEnvFlags, refProblem } from "./env-flags";

const usage = `USAGE
  shipwright env <subcommand> [OPTIONS]

DESCRIPTION
  Agent-built, reusable run environments (ADR-0020). A recipe (.shipwright/env.json) says how
  to install a repository's dependencies, which paths to keep, and which services its tests
  need. Environments are cached by a key of the recipe, the lockfiles and the toolchain, and
  restored into fresh worktrees by copy-on-write clone, on macOS and on GitHub Actions.

SUBCOMMANDS
  init       An agent writes the recipe; Shipwright proves it in a fresh clone and writes it back
  hydrate    Make a checkout ready: restore the cached environment or build and cache it
  key        Print the cache key (--json: key, cache directory and paths, for actions/cache)
  show       Print the recipe in effect (committed, working tree or detected)
  up [svc]   Start the recipe's services and wait until they answer
  down [svc] Stop the recipe's services
  list       List cached environments for this repository
  prune      Remove old cached environments

OPTIONS
  --root DIR          The repository the recipe and cache belong to (default: .)
  --dir DIR           The checkout to make ready (default: --root)
  --ref REF           Read the committed recipe at this git ref (default: HEAD)
  --worktree          Read .shipwright/env.json from --dir's working tree instead
  --trust-worktree    Allow an uncommitted recipe to run setup or services
  --restore-only      hydrate: restore from cache only; never run setup
  --no-detect         hydrate, key, show: do not fall back to a detected recipe
  --no-agent          init: prove the detected recipe without an agent
  --no-write          init: do not write the recipe into the working tree
  --attempts N        init: agent attempts (default 3)
  --model M           init: model alias (default sonnet)
  --effort E          init: low, medium, high, xhigh or max (default medium)
  --budget USD        init: agent budget per attempt (default 2)
  --keep N            prune: entries to keep (default 3)
  --max-age-days N    prune: remove entries unused this long (default 30)
  --dry-run           prune: list what would be removed
  --json              Machine-readable output
  --quiet             hydrate: print only failures

EXIT CODES
  0 ready (hit, built, skipped, no recipe)   1 setup, recipe or service failure   2 usage error

EXAMPLES
  shipwright env init                         Let an agent write and prove the recipe
  shipwright env hydrate --dir ../wt-123      Make a worktree ready before a pipeline runs
  shipwright env key --json                   Cache key and directory for GitHub Actions`;

const LOCATION = ["--root", "--dir", "--ref", "--worktree", "--no-detect", "--json"];
const SUBCOMMANDS: Record<string, { flags: readonly string[]; positional?: number }> = {
  init: {
    flags: [
      "--root",
      "--ref",
      "--json",
      "--no-agent",
      "--no-write",
      "--attempts",
      "--model",
      "--effort",
      "--budget",
    ],
  },
  hydrate: { flags: [...LOCATION, "--trust-worktree", "--restore-only", "--quiet"] },
  key: { flags: LOCATION },
  show: { flags: LOCATION },
  up: { flags: [...LOCATION, "--trust-worktree"], positional: 1 },
  down: { flags: [...LOCATION, "--trust-worktree"], positional: 1 },
  list: { flags: ["--root", "--json"] },
  prune: { flags: ["--root", "--json", "--keep", "--max-age-days", "--dry-run"] },
};

async function dispatch(
  sub: string,
  f: EnvFlags,
  io: CliIO,
  ctx: CommandContext,
): Promise<number | string> {
  const ports = ctx.environments();
  switch (sub) {
    case "init":
      return initAction(io, ports, f);
    case "hydrate":
      return hydrateAction(io, ports, f);
    case "key":
      return keyAction(io, ports, f);
    case "show":
      return showAction(io, ports, f);
    case "up":
    case "down":
      return servicesAction(io, ports, f, sub === "up");
    default:
      return listAction(io, ports, f, sub === "prune");
  }
}

export const envCommand: Command = {
  name: "env",
  aliases: [],
  summary: "Agent-built, cached run environments (recipe, hydrate, services)",
  usage,
  async run(args, ctx) {
    const { io } = ctx;
    if (isHelpRequest(args, Object.keys(SUBCOMMANDS))) {
      io.out(usage);
      return 0;
    }
    const [sub, ...rest] = args;
    const spec = sub === undefined ? undefined : SUBCOMMANDS[sub];
    if (sub === undefined || spec === undefined)
      return usageError(io, usage, sub ? `unknown subcommand: ${sub}` : "missing subcommand");
    const f = parseEnvFlags(rest, spec.flags, spec.positional ?? 0);
    if (typeof f === "string") return usageError(io, usage, f);
    const bad = f.values["--ref"] === undefined ? null : refProblem(f.values["--ref"]);
    if (bad) return usageError(io, usage, bad);
    const code = await dispatch(sub, f, io, ctx);
    return typeof code === "string" ? usageError(io, usage, code) : code;
  },
};
