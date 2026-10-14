import { join, resolve } from "node:path";
import { z } from "zod";
import { CONTEXTS } from "./contexts";

export const ROOT = resolve(import.meta.dir, "../..");
export const ROUTER_FILE = join(ROOT, "scripts/sw");
export const PROGRESS_FILE = join(ROOT, "docs/plans/port/progress.json");

export const Status = z.enum(["bash", "porting", "parity-green", "bash-deleted"]);
export const ProgressEntry = z
  .object({
    command: z.string(),
    aliases: z.array(z.string()),
    script: z.string(),
    context: z.enum(CONTEXTS),
    parity: z.string().nullable(),
    status: Status,
  })
  .strict();
export type ProgressEntry = z.infer<typeof ProgressEntry>;
export const Progress = z.array(ProgressEntry);

export interface RouterEntry {
  readonly command: string;
  readonly aliases: readonly string[];
  readonly script: string;
}

const LABEL = /^\s+((?:"")?\|?[a-z0-9][a-z0-9|-]*)\)\s*(.*)$/;
// Extra args after the script (`exec "$SCRIPT_DIR/sw-x.sh" sub "$@"`) are tolerated.
const TERMINATOR = /^\s*;;/;
const TARGET = /exec "\$SCRIPT_DIR\/(sw-[a-z0-9-]+\.sh)"/;

/** The exec target on the label line, or in the body that follows it up to `;;` or the next label. */
function findTarget(lines: readonly string[], i: number, rest: string): string | undefined {
  const first = rest.match(TARGET);
  if (first) return first[1];
  if (rest.includes(";;")) return undefined; // one-line entry that runs something else
  for (let j = i + 1; j < lines.length; j++) {
    const line = lines[j] ?? "";
    if (TERMINATOR.test(line) || LABEL.test(line)) return undefined;
    const m = line.match(TARGET);
    if (m) return m[1];
  }
  return undefined;
}

/** Adds names to the entry for the same script that already uses one of them, else appends. */
function addNames(out: RouterEntry[], names: string[], script: string): void {
  const i = out.findIndex(
    (e) => e.script === script && names.some((n) => n === e.command || e.aliases.includes(n)),
  );
  const existing = out[i];
  if (!existing) {
    const [command, ...aliases] = names;
    out.push({ command: command as string, aliases, script });
    return;
  }
  const known = new Set([existing.command, ...existing.aliases]);
  const added = names.filter((n) => !known.has(n));
  out[i] = { ...existing, aliases: [...existing.aliases, ...added] };
}

/**
 * Extracts `label) exec "$SCRIPT_DIR/sw-x.sh"` router entries, including multi-line bodies with guard calls before the exec.
 * A repeated name merges its aliases into the existing entry for that script; distinct commands may share a script.
 */
export function parseRouter(text: string): RouterEntry[] {
  const lines = text.split("\n");
  const out: RouterEntry[] = [];
  lines.forEach((line, i) => {
    const label = line.match(LABEL);
    if (!label) return;
    const script = findTarget(lines, i, label[2] ?? "");
    if (!script) return;
    const names = (label[1] as string).replace(/^""\|/, "").split("|");
    addNames(out, names, script);
  });
  return out;
}

export async function loadProgress(): Promise<ProgressEntry[]> {
  return Progress.parse(await Bun.file(PROGRESS_FILE).json());
}
