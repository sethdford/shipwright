import { loadProgress, type ProgressEntry, ROUTER_FILE } from "./progress";

// A command name, optionally quoted: hello, "hello" or 'hello'.
const NAME = String.raw`(["']?)([a-z0-9-]+)\1(?=[\s;)]|$)`;
// `run_ts <name>` helper calls and inline `bun $SCRIPT_DIR/../src/cli.ts <name>` (any quoting of
// $SCRIPT_DIR / ${SCRIPT_DIR}).
const TS_ROUTE = new RegExp(
  String.raw`(?:\brun_ts\s+|\bbun\s+"?\$(?:SCRIPT_DIR|\{SCRIPT_DIR\})/\.\./src/cli\.ts"?\s+)${NAME}`,
  "g",
);
// Anything that looks like a TypeScript route; a line like this must parse, or the gate fails closed.
const ROUTE_HINT = /src\/cli\.ts|\brun_ts\s/;
const RUN_TS_DEFINITION = /^\s*(?:function\s+)?run_ts\s*\(\s*\)/;
const READY = new Set(["parity-green", "bash-deleted"]);

const braceDelta = (line: string) =>
  (line.match(/\{/g)?.length ?? 0) - (line.match(/\}/g)?.length ?? 0);

/** Command names routed to TypeScript, plus a problem for each route line that cannot be parsed. */
function scanRoutes(router: string): { names: string[]; unparsed: string[] } {
  const names: string[] = [];
  const unparsed: string[] = [];
  let definitionDepth = 0;
  router.split("\n").forEach((line, index) => {
    if (definitionDepth > 0 || RUN_TS_DEFINITION.test(line)) {
      definitionDepth = Math.max(0, definitionDepth + braceDelta(line));
      return;
    }
    if (/^\s*#/.test(line) || !ROUTE_HINT.test(line)) return;
    const found = [...line.matchAll(TS_ROUTE)].map((m) => m[2] as string);
    if (found.length === 0) {
      unparsed.push(`line ${index + 1}: cannot parse the TypeScript route in: ${line.trim()}`);
    }
    names.push(...found);
  });
  return { names, unparsed };
}

export function routerProblems(router: string, progress: readonly ProgressEntry[]): string[] {
  const { names, unparsed } = scanRoutes(router);
  const routed = names.flatMap((name) => {
    const entry = progress.find((e) => e.command === name || e.aliases.includes(name));
    if (!entry) return [`${name} is routed to TypeScript but has no progress entry.`];
    return READY.has(entry.status)
      ? []
      : [
          `${name} is routed to TypeScript but its progress status is '${entry.status}' (needs parity-green).`,
        ];
  });
  return [...unparsed, ...routed];
}

if (import.meta.main) {
  const problems = routerProblems(await Bun.file(ROUTER_FILE).text(), await loadProgress());
  for (const p of problems) console.error(`PORT ${p}`);
  process.exit(problems.length ? 1 : 0);
}
