import { existsSync } from "node:fs";
import { join } from "node:path";
import { contextFor } from "./contexts";
import { PROGRESS_FILE, type ProgressEntry, parseRouter, ROOT, ROUTER_FILE } from "./progress";

const entries: ProgressEntry[] = parseRouter(await Bun.file(ROUTER_FILE).text()).map((e) => {
  const suite = `scripts/${e.script.replace(/\.sh$/, "-test.sh")}`;
  return {
    command: e.command,
    aliases: [...e.aliases],
    script: e.script,
    context: contextFor(e.script),
    parity: existsSync(join(ROOT, suite)) ? suite : null,
    status: "bash",
  };
});
await Bun.write(PROGRESS_FILE, `${JSON.stringify(entries, null, 2)}\n`);
console.log(`wrote ${entries.length} entries to ${PROGRESS_FILE}`);
