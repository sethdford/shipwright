import type { DeliveryPorts } from "../contexts/delivery";
import type { SafetyPorts } from "../contexts/orchestration";
import type { FileReader } from "../shared/kernel/ports";

export interface CliIO {
  out(text: string): void;
  err(text: string): void;
}

export interface CommandContext {
  readonly io: CliIO;
  readonly version: string;
  /** The process environment (read in main.ts; commands never touch process.env). */
  readonly env: Readonly<Record<string, string | undefined>>;
  /** Adapters for the safety commands, built on first call (commands that need none never call it). */
  readonly safety: () => SafetyPorts;
  /** File reads for commands; built by main.ts from the adapter (commands never touch node:fs). */
  readonly files: () => FileReader;
  /** Agents, worktrees and the test runner for the build tournament, built on first call. */
  readonly delivery: () => DeliveryPorts;
}

/** Metadata is the single source for help text and docs/reference/cli.md. */
export interface Command {
  readonly name: string;
  readonly aliases: readonly string[];
  readonly summary: string;
  readonly usage: string;
  run(args: readonly string[], ctx: CommandContext): Promise<number>;
}
