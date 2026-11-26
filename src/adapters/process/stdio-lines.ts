import { createInterface } from "node:readline";
import type { LineChannel } from "../../contexts/intelligence";

/** stdin and stdout of this process as an MCP stdio transport. */
export function processStdio(): LineChannel {
  return {
    lines: () => createInterface({ input: process.stdin, crlfDelay: Number.POSITIVE_INFINITY }),
    write: (line) => {
      process.stdout.write(`${line}\n`);
    },
  };
}
