/** Flag parsing for `shipwright governance`: value options, boolean switches, nothing positional. */
export interface GovFlags {
  readonly values: Readonly<Record<string, string>>;
  readonly switches: ReadonlySet<string>;
}

export const VALUE_FLAGS = [
  "--root",
  "--ref",
  "--issue",
  "--paths",
  "--changed",
  "--failure-class",
  "--fingerprint",
  "--log",
  "--kind",
  "--source",
] as const;

export const SWITCH_FLAGS = ["--json", "--no-lessons", "--no-governance"] as const;

export function parseGovFlags(
  args: readonly string[],
  allowed: readonly string[],
): GovFlags | string {
  const values: Record<string, string> = {};
  const switches = new Set<string>();
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? "";
    if (!allowed.includes(arg)) return `unknown option: ${arg}`;
    if ((SWITCH_FLAGS as readonly string[]).includes(arg)) {
      switches.add(arg);
      continue;
    }
    const value = args[i + 1];
    if (value === undefined || value.startsWith("--")) return `${arg} needs a value`;
    values[arg] = value;
    i++;
  }
  return { values, switches };
}

/** An ablation switch from the environment: off, 0, false or no (any case) turns the feature off. */
export function envOff(value: string | undefined): boolean {
  return ["off", "0", "false", "no"].includes((value ?? "").trim().toLowerCase());
}

/** One path per line; blank lines and surrounding space are dropped. */
export function pathLines(text: string): readonly string[] {
  return text
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
}
