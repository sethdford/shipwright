import {
  type BenchArm,
  type BenchManifest,
  type BenchPorts,
  type BenchRow,
  parseArms,
  parseManifest,
} from "../../contexts/quality";
import type { CommandContext } from "../command";
import type { BenchFlags } from "./bench-flags";

export class BenchError extends Error {}

export async function readJson(ctx: CommandContext, path: string): Promise<unknown> {
  const raw = await ctx.files().readText(path);
  if (!raw.ok) throw new BenchError(`cannot read ${path}: ${raw.error.message}`);
  try {
    return JSON.parse(raw.value);
  } catch {
    throw new BenchError(`${path} is not JSON`);
  }
}

export async function readJsonLines(ctx: CommandContext, path: string): Promise<unknown[]> {
  const raw = await ctx.files().readText(path);
  if (!raw.ok) throw new BenchError(`cannot read ${path}: ${raw.error.message}`);
  const lines = raw.value.split("\n").filter((l) => l.trim() !== "");
  return lines.map((line, i) => {
    try {
      return JSON.parse(line);
    } catch {
      throw new BenchError(`${path}:${i + 1} is not JSON`);
    }
  });
}

export async function loadManifest(ctx: CommandContext, flags: BenchFlags): Promise<BenchManifest> {
  const m = parseManifest(await readJson(ctx, flags.values.tasks ?? ""));
  if (!m.ok) throw new BenchError(`tasks: ${m.reason}`);
  return m.value;
}

export async function loadArms(
  ctx: CommandContext,
  flags: BenchFlags,
  filter = true,
): Promise<{ readonly baseline: string; readonly arms: readonly BenchArm[] }> {
  const a = parseArms(await readJson(ctx, flags.values.arms ?? ""));
  if (!a.ok) throw new BenchError(`arms: ${a.reason}`);
  const only = flags.values.arm;
  if (only === undefined || !filter) return a.value;
  const arms = a.value.arms.filter((x) => x.id === only);
  if (arms.length === 0) throw new BenchError(`--arm ${only} is not in the arms file`);
  return { baseline: a.value.baseline, arms };
}

export async function loadRows(ports: BenchPorts): Promise<readonly BenchRow[]> {
  const rows = await ports.store.rows();
  if (!rows.ok) throw new BenchError(rows.error.message);
  return rows.value;
}

export const portsFor = (ctx: CommandContext, flags: BenchFlags) =>
  ctx.bench().ports(flags.values.out ?? "");
