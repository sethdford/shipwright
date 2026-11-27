/** Flag parsing for `shipwright steward`. Every option takes a value; `--format` picks the output. */
export interface StewardFlags {
  readonly values: Readonly<Record<string, string>>;
  readonly json: boolean;
}

export function parseStewardFlags(
  args: readonly string[],
  allowed: readonly string[],
): StewardFlags | string {
  const values: Record<string, string> = {};
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? "";
    if (!allowed.includes(arg)) return `unknown option: ${arg}`;
    const value = args[i + 1];
    if (value === undefined || value.startsWith("--")) return `${arg} needs a value`;
    values[arg] = value;
    i++;
  }
  const format = values["--format"] ?? "text";
  if (format !== "text" && format !== "json") return "--format must be text or json";
  return { values, json: format === "json" };
}

export function prNumber(raw: string | undefined): number | string {
  if (raw === undefined) return "--pr is required";
  return /^[1-9]\d{0,8}$/.test(raw) ? Number(raw) : "--pr must be a PR number";
}

export function intIn(
  name: string,
  raw: string | undefined,
  fallback: number,
  max: number,
): number | string {
  if (raw === undefined) return fallback;
  if (!/^\d{1,3}$/.test(raw) || Number(raw) > max)
    return `${name} must be a whole number from 0 to ${max}`;
  return Number(raw);
}

/** Comma-separated Actions job ids. */
export function jobIds(raw: string | undefined): number[] | string {
  if (raw === undefined || raw.trim() === "") return "--jobs is required";
  const ids = raw.split(",").map((s) => s.trim());
  if (!ids.every((s) => /^[1-9]\d{0,15}$/.test(s))) return "--jobs must be comma-separated job ids";
  return ids.map(Number);
}

/** Lowercased bot logins (claude[bot], or a Bot-typed login such as copilot); empty means the defaults. */
export function botList(
  raw: string | undefined,
  fallback: readonly string[],
): Set<string> | string {
  if (raw === undefined || raw.trim() === "") return new Set(fallback);
  const bots = raw
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  if (!bots.every((b) => /^[a-z0-9-]+(\[bot\])?$/.test(b)))
    return "--bots must be bot logins like claude[bot]";
  return new Set(bots);
}
