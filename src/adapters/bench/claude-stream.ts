import { z } from "zod";

const Content = z.object({
  type: z.string(),
  name: z.string().optional(),
  input: z.record(z.string(), z.unknown()).optional(),
});
const Event = z
  .object({
    type: z.string().optional(),
    total_cost_usd: z.number().optional(),
    is_error: z.boolean().optional(),
    message: z.object({ content: z.array(z.unknown()).optional() }).optional(),
  })
  .passthrough();

export interface ClaudeRun {
  readonly costUsd: number | null;
  readonly isError: boolean;
  /** One line per tool call: the Bash command, or `<Tool> <path or pattern>`. */
  readonly commands: readonly string[];
}

const text = (v: unknown) => (typeof v === "string" ? v : "");

function describe(name: string, input: Record<string, unknown>): string {
  if (name === "Bash") return text(input.command);
  const where = [
    input.file_path,
    input.path,
    input.notebook_path,
    input.pattern,
    input.url,
    input.query,
  ]
    .map(text)
    .filter((s) => s !== "");
  return `${name} ${where.join(" ") || JSON.stringify(input).slice(0, 300)}`;
}

function toolCalls(content: readonly unknown[]): string[] {
  const out: string[] = [];
  for (const item of content) {
    const c = Content.safeParse(item);
    if (c.success && c.data.type === "tool_use" && c.data.name)
      out.push(describe(c.data.name, c.data.input ?? {}));
  }
  return out;
}

function parseLine(line: string): z.infer<typeof Event> | null {
  try {
    const e = Event.safeParse(JSON.parse(line));
    return e.success ? e.data : null;
  } catch {
    return null;
  }
}

/**
 * Reads `claude -p --output-format stream-json --verbose` (one JSON event per line) or the older
 * single `--output-format json` object. The `result` event carries the spend; a run with no
 * result event is an error.
 */
export function parseClaudeStream(stdout: string): ClaudeRun {
  let result: z.infer<typeof Event> | null = null;
  const commands: string[] = [];
  for (const line of stdout.split("\n")) {
    if (line.trim() === "") continue;
    const e = parseLine(line.trim());
    if (e === null) continue;
    if (e.type === "assistant") commands.push(...toolCalls(e.message?.content ?? []));
    // `result` closes a stream; the older single-object format has no `type` at all.
    if (e.type === "result" || e.type === undefined) result = e;
  }
  if (result === null) return { costUsd: null, isError: true, commands };
  return {
    costUsd: result.total_cost_usd ?? null,
    isError: result.is_error === true,
    commands,
  };
}
