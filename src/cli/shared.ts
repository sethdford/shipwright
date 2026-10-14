import type { AdapterError } from "../shared/kernel/ports";
import type { CliIO } from "./command";

export const isHelp = (arg: string | undefined): boolean => arg === "--help" || arg === "-h";

/** Bad arguments: message on stderr, usage on stdout, exit 2 (the CLI's usage-error code). */
export function usageError(io: CliIO, usage: string, message: string): number {
  io.err(`✗ ${message}`);
  io.out(usage);
  return 2;
}

/**
 * Gates fail closed: a source that cannot be read blocks, with exit 1. Exception: `paused` has
 * inverted semantics (0 = paused); scripts use `paused --gate` (0 = safe to dispatch).
 */
export function adapterFailure(io: CliIO, what: string, error: AdapterError): number {
  io.err(`✗ ${what}: cannot verify (${error.kind}): ${error.message}`);
  return 1;
}
