import type { RepoSession } from "./session";
import { callTool, toolSpecs } from "./tools";

/** The MCP server name: tool permission rules read `mcp__repomodel__<tool>`. */
export const MCP_SERVER_NAME = "repomodel";
const PROTOCOL_VERSION = "2025-06-18";

type Id = string | number | null;

interface Request {
  readonly id?: Id;
  readonly method?: unknown;
  readonly params?: unknown;
}

function reply(id: Id, result: unknown): string {
  return JSON.stringify({ jsonrpc: "2.0", id, result });
}

function fail(id: Id, code: number, message: string): string {
  return JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } });
}

function parse(line: string): Request | undefined {
  try {
    const v: unknown = JSON.parse(line);
    return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Request) : undefined;
  } catch {
    return undefined;
  }
}

function record(v: unknown): Readonly<Record<string, unknown>> {
  return v !== null && typeof v === "object" && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : {};
}

async function dispatch(
  session: RepoSession,
  version: string,
  req: Request,
  id: Id,
): Promise<string> {
  const params = record(req.params);
  switch (req.method) {
    case "initialize": {
      const asked =
        typeof params.protocolVersion === "string" ? params.protocolVersion : PROTOCOL_VERSION;
      return reply(id, {
        protocolVersion: asked,
        capabilities: { tools: {} },
        serverInfo: { name: MCP_SERVER_NAME, version },
      });
    }
    case "ping":
      return reply(id, {});
    case "tools/list":
      return reply(id, { tools: toolSpecs() });
    case "tools/call": {
      const out = await callTool(session, String(params.name ?? ""), record(params.arguments));
      return reply(id, { content: [{ type: "text", text: out.text }], isError: out.isError });
    }
    default:
      return fail(id, -32601, `Method not found: ${String(req.method)}`);
  }
}

/**
 * Handles one line of a stdio MCP session (JSON-RPC 2.0, one message per line). Returns the line to write
 * back, or undefined for a notification. The server is read-only: its tools only read the working tree.
 */
export async function handleMcpLine(
  session: RepoSession,
  version: string,
  line: string,
): Promise<string | undefined> {
  if (line.trim().length === 0) return undefined;
  const req = parse(line);
  if (!req) return fail(null, -32700, "Parse error");
  const isNotification = req.id === undefined;
  if (isNotification) return undefined;
  const id: Id = typeof req.id === "string" || typeof req.id === "number" ? req.id : null;
  if (typeof req.method !== "string") return fail(id, -32600, "Invalid request");
  return dispatch(session, version, req, id);
}
