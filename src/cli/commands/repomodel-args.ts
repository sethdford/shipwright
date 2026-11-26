import type { CommandContext } from "../command";

/** Arguments of `shipwright repomodel <sub>`: one positional for the query subcommands, then flags. */
export interface ModelArgs {
  readonly positional: string;
  readonly values: Readonly<Record<string, string>>;
  readonly switches: ReadonlySet<string>;
}

const VALUES: Readonly<Record<string, readonly string[]>> = {
  build: ["--root"],
  search: ["--root", "--limit"],
  map: ["--root", "--focus", "--budget"],
  localize: ["--root", "--task", "--limit"],
  brief: ["--root", "--task"],
  impact: ["--root", "--diff"],
  mcp: ["--root"],
};

const SWITCHES: Readonly<Record<string, readonly string[]>> = {
  build: ["--json"],
  brief: ["--json", "--with-tools"],
  impact: ["--json"],
};

function positiveInt(v: string): boolean {
  return /^[1-9][0-9]{0,5}$/.test(v);
}

function parseFlags(sub: string, args: readonly string[]) {
  const values: Record<string, string> = {};
  const switches = new Set<string>();
  const allowedValues = VALUES[sub] ?? ["--root"];
  const allowedSwitches = SWITCHES[sub] ?? [];
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i] ?? "";
    if (allowedSwitches.includes(arg)) {
      switches.add(arg);
      continue;
    }
    if (!allowedValues.includes(arg)) return `unknown option: ${arg}`;
    const value = args[i + 1];
    if (value === undefined || value.startsWith("--")) return `${arg} needs a value`;
    if ((arg === "--limit" || arg === "--budget") && !positiveInt(value))
      return `${arg} must be a positive integer`;
    values[arg] = value;
    i += 1;
  }
  return { values, switches };
}

export function parseModelArgs(
  sub: string,
  args: readonly string[],
  needsPositional: boolean,
): ModelArgs | string {
  let positional = "";
  let rest = args;
  if (needsPositional) {
    const first = args[0];
    if (first === undefined || first.startsWith("--")) return `${sub} needs an argument`;
    positional = first;
    rest = args.slice(1);
  }
  const flags = parseFlags(sub, rest);
  if (typeof flags === "string") return flags;
  if (sub === "brief" && flags.values["--task"] === undefined) return "brief needs --task FILE";
  if (sub === "localize" && flags.values["--task"] === undefined)
    return "localize needs --task FILE";
  if (sub === "impact" && flags.values["--diff"] === undefined) return "impact needs --diff FILE";
  return { positional, ...flags };
}

/** The repository root as an absolute path (the model cache is keyed by it): --root, else the working directory. */
export function rootOf(ctx: CommandContext, a: ModelArgs): string {
  const given = a.values["--root"] ?? ".";
  const cwd = ctx.env.PWD ?? "";
  const abs =
    given.startsWith("/") || cwd.length === 0 ? given : `${cwd.replace(/\/$/, "")}/${given}`;
  return normalizeAbs(abs);
}

function normalizeAbs(path: string): string {
  const parts: string[] = [];
  for (const p of path.split("/")) {
    if (p === "" || p === ".") continue;
    if (p === "..") parts.pop();
    else parts.push(p);
  }
  return path.startsWith("/") ? `/${parts.join("/")}` : parts.join("/") || ".";
}
