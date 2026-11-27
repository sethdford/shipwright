import type { DeliveryPorts, StewardPorts } from "../contexts/delivery";
import type { RepoDocs } from "../contexts/governance";
import type { LineChannel, RepoModelPorts, RoutingPorts } from "../contexts/intelligence";
import type { SafetyPorts } from "../contexts/orchestration";
import type { AcceptancePorts } from "../contexts/planning";
import type { BenchFactory, ProofPorts, QualityPorts, VerifierPorts } from "../contexts/quality";
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
  /** Read-only delivery data for the scorecard, built on first call. */
  readonly quality: () => QualityPorts;
  /** Git, GitHub reads, the stored model and the critic agent for `verify`, built on first call. */
  readonly verifier: () => VerifierPorts;
  /** Governance documents and lessons from git (ADR-0010), built by main.ts. */
  readonly repoDocs: () => RepoDocs;
  /** Agents, worktrees and the test runner for the build tournament, built on first call. */
  readonly delivery: () => DeliveryPorts;
  /** Acceptance-test ports for a repository root (default: the working directory), built by main.ts. */
  readonly acceptance: (root?: string) => AcceptancePorts;
  /** The repository world model's adapters (ADR-0016), built by main.ts. */
  readonly repoModel: () => RepoModelPorts;
  /** This process's stdin and stdout as lines, for a stdio server (the MCP transport). */
  readonly stdio: () => LineChannel;
  /** The routing log and clock for `shipwright route` (ADR-0014), built by main.ts. */
  readonly routing: () => RoutingPorts;
  /** Benchmark adapters (workspaces, agents, grader, results store), built on first call. */
  readonly bench: () => BenchFactory;
  /** GitHub reads and writes and the local diff for the PR steward (ADR-0017), built on first call. */
  readonly steward: () => StewardPorts;
  /** Run-the-app proof adapters for the working directory (ADR-0019); null outDir = state dir. */
  readonly proof: (outDir: string | null) => ProofPorts;
}

/** Metadata is the single source for help text and docs/reference/cli.md. */
export interface Command {
  readonly name: string;
  readonly aliases: readonly string[];
  readonly summary: string;
  readonly usage: string;
  run(args: readonly string[], ctx: CommandContext): Promise<number>;
}
