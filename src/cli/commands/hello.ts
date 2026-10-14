import { hello } from "../../contexts/platform";
import type { Command } from "../command";

const usage = `USAGE
  shipwright hello [OPTIONS]

DESCRIPTION
  A simple hello world command.

OPTIONS
  --help, -h      Show this help text
  --version, -v   Show version

EXAMPLES
  shipwright hello                 Print "hello world"
  shipwright hello --help          Show this help text`;

export const helloCommand: Command = {
  name: "hello",
  aliases: [],
  summary: "Print hello world (CLI smoke test)",
  usage,
  async run(args, { io, version }) {
    const [arg] = args;
    if (arg === undefined) {
      io.out(hello());
      return 0;
    }
    if (arg === "--help" || arg === "-h") {
      io.out(usage);
      return 0;
    }
    if (arg === "--version" || arg === "-v") {
      io.out(version);
      return 0;
    }
    io.err(`✗ Unknown option: ${arg}`);
    io.out(usage);
    return 1;
  },
};
