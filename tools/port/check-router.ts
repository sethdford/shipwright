import { loadProgress, type ProgressEntry, ROUTER_FILE } from "./progress";

const TS_ROUTE = /bun "\$SCRIPT_DIR\/\.\.\/src\/cli\.ts" ([a-z0-9-]+)/g;
const READY = new Set(["parity-green", "bash-deleted"]);

export function routerProblems(router: string, progress: readonly ProgressEntry[]): string[] {
  return [...router.matchAll(TS_ROUTE)].flatMap(([, name]) => {
    const entry = progress.find((e) => e.command === name || e.aliases.includes(name as string));
    if (!entry) return [`${name} is routed to TypeScript but has no progress entry.`];
    return READY.has(entry.status)
      ? []
      : [
          `${name} is routed to TypeScript but its progress status is '${entry.status}' (needs parity-green).`,
        ];
  });
}

if (import.meta.main) {
  const problems = routerProblems(await Bun.file(ROUTER_FILE).text(), await loadProgress());
  for (const p of problems) console.error(`PORT ${p}`);
  process.exit(problems.length ? 1 : 0);
}
