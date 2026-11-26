import {
  analyzeChange,
  buildBrief,
  callTool,
  handleMcpLine,
  RepoSession,
  refreshModel,
} from "../../contexts/intelligence";
import type { Command, CommandContext } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";
import { envOff } from "./governance-flags";
import { type ModelArgs, parseModelArgs, rootOf } from "./repomodel-args";

const usage = `USAGE
  shipwright repomodel build    [--root DIR] [--json]
  shipwright repomodel search   QUERY [--limit N] [--root DIR]
  shipwright repomodel def      NAME            (where NAME is defined; Class.method works)
  shipwright repomodel refs     NAME            (every use, with the enclosing definition)
  shipwright repomodel outline  PATH
  shipwright repomodel deps     PATH
  shipwright repomodel tests    PATH
  shipwright repomodel owners   PATH
  shipwright repomodel map      [--focus FILE] [--budget CHARS]
  shipwright repomodel localize --task FILE [--limit N]
  shipwright repomodel brief    --task FILE [--with-tools] [--json]
  shipwright repomodel impact   --diff FILE [--json]
  shipwright repomodel mcp      [--root DIR]

DESCRIPTION
  A persistent, incrementally updated model of a repository (ADR-0016): definitions, imports, a reference graph,
  a search index, a test-to-code map and ownership. It is rebuilt only for files whose content changed, and
  every query refreshes it first, so answers include uncommitted edits. The cache lives in the state directory.

  build     Refresh the model and print what changed.
  brief     The prompt section for a task (--task FILE): likely files and definitions with their tests and
            owners; with --with-tools, also how to use the MCP tools. Prints nothing when SHIPWRIGHT_REPO_MODEL=off.
  impact    For a unified diff (--diff FILE, as git diff prints it): the definitions it edits, the files outside
            the change that import or use them, linked tests it does or does not change, and deleted files that
            are still imported. The review stage and the merge critic read it. Prints nothing when off.
  mcp       A read-only MCP server on stdio (server name "repomodel") with the same queries as tools.

ABLATION (for paired eval runs)
  SHIPWRIGHT_REPO_MODEL=off leaves the brief and the impact section out, and the pipeline does not attach the MCP server.

EXIT CODES
  0  done      1  the repository could not be read      2  usage error`;

const TOOL_OF: Readonly<Record<string, { tool: string; arg: string }>> = {
  search: { tool: "search", arg: "query" },
  def: { tool: "definition", arg: "name" },
  refs: { tool: "references", arg: "name" },
  outline: { tool: "outline", arg: "path" },
  deps: { tool: "dependencies", arg: "path" },
  tests: { tool: "tests_for", arg: "path" },
  owners: { tool: "owners", arg: "path" },
};

const SUBCOMMANDS = [...Object.keys(TOOL_OF), "build", "map", "localize", "brief", "impact", "mcp"];

async function build(ctx: CommandContext, a: ModelArgs): Promise<number> {
  const r = await refreshModel(ctx.repoModel(), rootOf(ctx, a));
  if (!r.ok) return adapterFailure(ctx.io, "repository model", r.error);
  const s = r.value.stats;
  if (a.switches.has("--json")) ctx.io.out(JSON.stringify({ ...s, changed: r.value.changed }));
  else
    ctx.io.out(
      `✓ ${s.files} files (${s.extracted} re-read, ${s.reused} reused, ${s.removed} removed)`,
    );
  return 0;
}

async function query(
  ctx: CommandContext,
  a: ModelArgs,
  tool: string,
  args: Record<string, unknown>,
) {
  const out = await callTool(new RepoSession(ctx.repoModel(), rootOf(ctx, a)), tool, args);
  if (out.isError) {
    ctx.io.err(`✗ ${out.text}`);
    return out.text.startsWith("Repository model unavailable") ? 1 : 2;
  }
  ctx.io.out(out.text);
  return 0;
}

async function readTask(ctx: CommandContext, a: ModelArgs): Promise<string | number> {
  const file = a.values["--task"] ?? a.values["--focus"];
  if (file === undefined) return "";
  const r = await ctx.files().readText(file);
  return r.ok ? r.value : adapterFailure(ctx.io, `read ${file}`, r.error);
}

async function brief(ctx: CommandContext, a: ModelArgs): Promise<number> {
  if (envOff(ctx.env.SHIPWRIGHT_REPO_MODEL)) {
    if (a.switches.has("--json")) ctx.io.out(JSON.stringify({ brief: "", files: [], arm: "off" }));
    return 0;
  }
  const task = await readTask(ctx, a);
  if (typeof task === "number") return task;
  const session = new RepoSession(ctx.repoModel(), rootOf(ctx, a));
  const r = await buildBrief(session, task, a.switches.has("--with-tools"));
  if (!r.ok) return adapterFailure(ctx.io, "repository model", r.error);
  if (a.switches.has("--json")) {
    ctx.io.out(
      JSON.stringify({
        brief: r.value.text,
        files: r.value.files,
        stats: r.value.stats,
        arm: "on",
      }),
    );
  } else if (r.value.text.length > 0) ctx.io.out(r.value.text);
  return 0;
}

async function impact(ctx: CommandContext, a: ModelArgs): Promise<number> {
  const json = a.switches.has("--json");
  if (envOff(ctx.env.SHIPWRIGHT_REPO_MODEL)) {
    if (json) ctx.io.out(JSON.stringify({ text: "", arm: "off" }));
    return 0;
  }
  const file = a.values["--diff"] ?? "";
  const patch = await ctx.files().readText(file);
  if (!patch.ok) return adapterFailure(ctx.io, `read ${file}`, patch.error);
  const r = await analyzeChange(new RepoSession(ctx.repoModel(), rootOf(ctx, a)), patch.value);
  if (!r.ok) return adapterFailure(ctx.io, "repository model", r.error);
  if (json) ctx.io.out(JSON.stringify({ text: r.value.text, ...r.value.impact, arm: "on" }));
  else if (r.value.text.length > 0) ctx.io.out(r.value.text);
  return 0;
}

async function serve(ctx: CommandContext, a: ModelArgs): Promise<number> {
  const session = new RepoSession(ctx.repoModel(), rootOf(ctx, a));
  const channel = ctx.stdio();
  for await (const line of channel.lines()) {
    const out = await handleMcpLine(session, ctx.version, line);
    if (out !== undefined) channel.write(out);
  }
  return 0;
}

async function dispatch(ctx: CommandContext, sub: string, a: ModelArgs): Promise<number> {
  const mapped = TOOL_OF[sub];
  if (mapped) {
    const limit = a.values["--limit"];
    return query(ctx, a, mapped.tool, {
      [mapped.arg]: a.positional,
      ...(limit ? { limit: Number(limit) } : {}),
    });
  }
  if (sub === "build") return build(ctx, a);
  if (sub === "brief") return brief(ctx, a);
  if (sub === "impact") return impact(ctx, a);
  if (sub === "mcp") return serve(ctx, a);
  const task = await readTask(ctx, a);
  if (typeof task === "number") return task;
  if (sub === "map") {
    const budget = Math.ceil(Number(a.values["--budget"] ?? "6000") / 100);
    return query(ctx, a, "repo_map", { focus: task, budget });
  }
  return query(ctx, a, "localize", {
    task,
    ...(a.values["--limit"] ? { limit: Number(a.values["--limit"]) } : {}),
  });
}

export const repomodelCommand: Command = {
  name: "repomodel",
  aliases: ["code"],
  summary:
    "Query the repository world model: definitions, references, tests, owners, repo map (ADR-0016)",
  usage,
  async run(args, ctx) {
    if (isHelpRequest(args, SUBCOMMANDS)) {
      ctx.io.out(usage);
      return 0;
    }
    const [sub, ...rest] = args;
    if (sub === undefined || !SUBCOMMANDS.includes(sub)) {
      return usageError(
        ctx.io,
        usage,
        sub === undefined ? "missing subcommand" : `unknown subcommand: ${sub}`,
      );
    }
    const parsed = parseModelArgs(sub, rest, sub in TOOL_OF);
    if (typeof parsed === "string") return usageError(ctx.io, usage, parsed);
    return dispatch(ctx, sub, parsed);
  },
};
