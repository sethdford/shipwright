import { EFFORTS, type Effort } from "../../contexts/intelligence";

/** Flag parsing for `shipwright env`. Switches are listed; every other flag takes a value. */
export interface EnvFlags {
  readonly values: Readonly<Record<string, string>>;
  readonly switches: ReadonlySet<string>;
  readonly positional: readonly string[];
}

export const SWITCHES = new Set([
  "--json",
  "--quiet",
  "--worktree",
  "--trust-worktree",
  "--restore-only",
  "--no-detect",
  "--no-agent",
  "--no-write",
  "--dry-run",
]);

export function parseEnvFlags(
  args: readonly string[],
  allowed: readonly string[],
  maxPositional = 0,
): EnvFlags | string {
  const values: Record<string, string> = {};
  const switches = new Set<string>();
  const positional: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? "";
    if (!arg.startsWith("--")) {
      if (positional.length >= maxPositional) return `unexpected argument: ${arg}`;
      positional.push(arg);
      continue;
    }
    if (!allowed.includes(arg)) return `unknown option: ${arg}`;
    if (SWITCHES.has(arg)) {
      switches.add(arg);
      continue;
    }
    const value = args[i + 1];
    if (value === undefined || value.startsWith("--")) return `${arg} needs a value`;
    values[arg] = value;
    i++;
  }
  return { values, switches, positional };
}

export function intIn(
  name: string,
  raw: string | undefined,
  def: number,
  min: number,
  max: number,
): number | string {
  if (raw === undefined) return def;
  const n = /^\d{1,6}$/.test(raw) ? Number(raw) : Number.NaN;
  return n >= min && n <= max ? n : `${name} must be a whole number from ${min} to ${max}`;
}

export function usdIn(name: string, raw: string | undefined, def: number): number | string {
  if (raw === undefined) return def;
  const n = /^\d+(\.\d+)?$/.test(raw) ? Number(raw) : Number.NaN;
  return n > 0 && n <= 100 ? n : `${name} must be a USD amount above 0 and at most 100`;
}

export function effortOf(raw: string | undefined): { effort: Effort } | string {
  if (raw === undefined) return { effort: "medium" };
  const known = (EFFORTS as readonly string[]).includes(raw);
  return known ? { effort: raw as Effort } : `--effort must be one of ${EFFORTS.join(", ")}`;
}

/** A git ref as an argument: no option-looking or path-escaping values reach git. */
export function refOf(raw: string | undefined): string {
  return raw ?? "HEAD";
}
export function refProblem(ref: string): string | null {
  return /^[A-Za-z0-9][A-Za-z0-9._/@{}^~-]{0,199}$/.test(ref) && !ref.includes("..")
    ? null
    : `--ref is not a git ref: ${ref}`;
}
