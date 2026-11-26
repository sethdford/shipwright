import type { RepoDocs } from "../contexts/governance";
import type { LineChannel, RepoModelPorts } from "../contexts/intelligence";
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
  /** Governance documents and lessons from git (ADR-0010), built by main.ts. */
  readonly repoDocs: () => RepoDocs;
  /** The repository world model's adapters (ADR-0012), built by main.ts. */
  readonly repoModel: () => RepoModelPorts;
  /** This process's stdin and stdout as lines, for a stdio server (the MCP transport). */
  readonly stdio: () => LineChannel;
}

/** Metadata is the single source for help text and docs/reference/cli.md. */
export interface Command {
  readonly name: string;
  readonly aliases: readonly string[];
  readonly summary: string;
  readonly usage: string;
  run(args: readonly string[], ctx: CommandContext): Promise<number>;
}
