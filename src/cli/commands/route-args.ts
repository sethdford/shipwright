import {
  EFFORTS,
  type Effort,
  type IssueText,
  OUTCOME_RESULTS,
  type OutcomeResult,
  type RouteOverrides,
  type RouterMode,
} from "../../contexts/intelligence";

/** Flag parsing and input validation for `shipwright route`. Values only; `--json` is the switch. */
export interface RouteFlags {
  readonly values: Readonly<Record<string, string>>;
  readonly json: boolean;
}

export function parseRouteFlags(
  args: readonly string[],
  allowed: readonly string[],
): RouteFlags | string {
  const values: Record<string, string> = {};
  let json = false;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? "";
    if (arg === "--json" && allowed.includes(arg)) {
      json = true;
      continue;
    }
    if (!allowed.includes(arg)) return `unknown option: ${arg}`;
    const value = args[i + 1];
    if (value === undefined || value.startsWith("--")) return `${arg} needs a value`;
    values[arg] = value;
    i++;
  }
  return { values, json };
}

/** SHIPWRIGHT_ROUTER or --mode: shadow (default) or apply. "off" is handled by the bash caller. */
export function modeOf(flag: string | undefined, env: string | undefined): RouterMode | string {
  const raw = (flag ?? env ?? "shadow").trim().toLowerCase();
  if (raw === "" || raw === "shadow") return "shadow";
  if (raw === "apply") return "apply";
  return `mode must be shadow or apply, not ${raw}`;
}

export function positiveInt(name: string, raw: string | undefined): number | undefined | string {
  if (raw === undefined) return undefined;
  return /^[1-9]\d{0,8}$/.test(raw) ? Number(raw) : `${name} must be a positive whole number`;
}

export function usd(name: string, raw: string | undefined): number | undefined | string {
  if (raw === undefined) return undefined;
  return /^-?\d+(\.\d+)?$/.test(raw.trim()) ? Number(raw) : `${name} must be a number of USD`;
}

export function overridesOf(values: Readonly<Record<string, string>>): RouteOverrides | string {
  const effort = values["--effort"];
  if (effort !== undefined && !(EFFORTS as readonly string[]).includes(effort)) {
    return `--effort must be one of ${EFFORTS.join(", ")}`;
  }
  const attempts = positiveInt("--attempts", values["--attempts"]);
  if (typeof attempts === "string") return attempts;
  const template = values["--template"];
  const model = values["--model"];
  return {
    ...(template === undefined ? {} : { template }),
    ...(model === undefined ? {} : { model }),
    ...(effort === undefined ? {} : { effort: effort as Effort }),
    ...(attempts === undefined ? {} : { attempts }),
  };
}

export function resultOf(raw: string | undefined): OutcomeResult | string {
  if (raw !== undefined && (OUTCOME_RESULTS as readonly string[]).includes(raw)) {
    return raw as OutcomeResult;
  }
  return `--result must be one of ${OUTCOME_RESULTS.join(", ")}`;
}

const labelName = (l: unknown): string | undefined => {
  if (typeof l === "string") return l;
  if (l !== null && typeof l === "object" && typeof (l as { name?: unknown }).name === "string") {
    return (l as { name: string }).name;
  }
  return undefined;
};

/** `gh issue view --json title,body,labels` output (labels as names or objects with a name). */
export function issueFromJson(text: string): IssueText | string {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return "--issue-json is not valid JSON";
  }
  if (value === null || typeof value !== "object") return "--issue-json must hold an object";
  const v = value as { title?: unknown; body?: unknown; labels?: unknown };
  if (typeof v.title !== "string") return "--issue-json needs a string title";
  const labels = Array.isArray(v.labels) ? v.labels.map(labelName) : [];
  return {
    title: v.title,
    body: typeof v.body === "string" ? v.body : "",
    labels: labels.filter((l): l is string => l !== undefined),
  };
}
