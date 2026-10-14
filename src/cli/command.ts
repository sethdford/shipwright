export interface CliIO {
  out(text: string): void;
  err(text: string): void;
}

export interface CommandContext {
  readonly io: CliIO;
  readonly version: string;
}

/** Metadata is the single source for help text and docs/reference/cli.md. */
export interface Command {
  readonly name: string;
  readonly aliases: readonly string[];
  readonly summary: string;
  readonly usage: string;
  run(args: readonly string[], ctx: CommandContext): Promise<number>;
}
