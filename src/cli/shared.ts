import type { AdapterError } from "../shared/kernel/ports";
import type { CliIO, CommandContext } from "./command";

export const isHelp = (arg: string | undefined): boolean => arg === "--help" || arg === "-h";

/**
 * Help only when it is the whole request: `[h]`, or `[sub, h]` for one of `subcommands`. A help
 * flag anywhere else (say, as an option's value) falls through to argument parsing and exits 2,
 * so a gate can never exit 0 just because `-h` appeared somewhere.
 */
export function isHelpRequest(
  args: readonly string[],
  subcommands: readonly string[] = [],
): boolean {
  if (args.length === 1) return isHelp(args[0]);
  return args.length === 2 && subcommands.includes(args[0] ?? "") && isHelp(args[1]);
}

/** Bad arguments: message on stderr, usage on stdout, exit 2 (the CLI's usage-error code). */
export function usageError(io: CliIO, usage: string, message: string): number {
  io.err(`✗ ${message}`);
  io.out(usage);
  return 2;
}

/**
 * True on GitHub Actions: GITHUB_ACTIONS set to anything but empty or "false" (any case), so a
 * mis-cased or unusual value never reads as "not on Actions".
 */
export function onGithubActions(env: CommandContext["env"]): boolean {
  const value = (env.GITHUB_ACTIONS ?? "").trim().toLowerCase();
  return value !== "" && value !== "false";
}

/**
 * No-GitHub mode for a gate command. On Actions it is refused: prints the usage error and returns
 * false. Elsewhere it warns on stderr which checks are skipped and returns true.
 */
export function allowNoGithub(
  io: CliIO,
  usage: string,
  env: CommandContext["env"],
  unchecked: string,
): boolean {
  if (onGithubActions(env)) {
    usageError(io, usage, "no-GitHub mode is not allowed on GitHub Actions");
    return false;
  }
  io.err(`⚠ no-GitHub mode: not checked: ${unchecked}`);
  return true;
}

/**
 * Gates fail closed: a source that cannot be read blocks, with exit 1. Exception: `paused` has
 * inverted semantics (0 = paused); scripts use `paused --gate` (0 = safe to dispatch).
 */
export function adapterFailure(io: CliIO, what: string, error: AdapterError): number {
  io.err(`✗ ${what}: cannot verify (${error.kind}): ${error.message}`);
  return 1;
}
