import pkg from "../package.json";
import type { CliIO, Command } from "./cli/command";
import { commands, findCommand } from "./cli/commands";

const consoleIO: CliIO = {
  out: (text) => process.stdout.write(`${text}\n`),
  err: (text) => process.stderr.write(`${text}\n`),
};

// TODO(signals): install signal handlers that call runner.killAll when the first command constructs a BunProcessRunner.

/** Composition root. Adapters are constructed here as commands start needing them. */
export async function main(
  argv: readonly string[],
  io: CliIO = consoleIO,
  registry: readonly Command[] = commands,
): Promise<number> {
  const [name, ...args] = argv;
  if (name === undefined || name === "--help" || name === "-h") {
    io.out(registry.map((c) => `  ${c.name.padEnd(20)} ${c.summary}`).join("\n"));
    return 0;
  }
  const command = findCommand(name, registry);
  if (!command) {
    io.err(`✗ Unknown command: ${name}`);
    return 2;
  }
  try {
    return await command.run(args, { io, version: pkg.version });
  } catch (error) {
    io.err(`✗ ${error instanceof Error ? error.message : String(error)}`);
    return 1;
  }
}
