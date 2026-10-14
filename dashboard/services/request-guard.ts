// Request guard for the dashboard (spec §6.2 "Dashboard exposure", #8534).
// Pure: no environment reads and no I/O. server.ts builds the config at startup and calls
// guardRequest() before any route and withCors() on every response.
//
// Who authenticates how:
// - Browser UI: the existing `fleet_session` cookie (HttpOnly, SameSite=Lax) set after GitHub
//   OAuth or PAT login. The browser never holds the fleet token; WebSockets use the same cookie.
// - Fleet workers (claim, connect, CI webhook): `X-Shipwright-Token` (or `Authorization: Bearer`)
//   matching SHIPWRIGHT_FLEET_TOKEN / SHIPWRIGHT_FLEET_TOKEN_FILE. Never a query parameter.
// - auth=none (no OAuth/PAT configured) is allowed only on a loopback bind.

export interface GuardConfig {
  /** Shared fleet token (SHIPWRIGHT_FLEET_TOKEN). Empty when none is configured. */
  readonly fleetToken: string;
  /** Address the server binds to. */
  readonly host: string;
  /** Exact origins allowed for CORS and for mutating browser requests. */
  readonly allowedOrigins: readonly string[];
}

type Env = Readonly<Record<string, string | undefined>>;

export const TOKEN_HEADER = "x-shipwright-token";
const MUTATING = new Set(["POST", "PUT", "PATCH", "DELETE"]);
const LOOPBACK = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);

export function isLoopbackHost(host: string): boolean {
  return LOOPBACK.has(host.toLowerCase());
}

/** Fleet worker routes: claims, connect presence and CI webhooks. Browsers never call these. */
export function isFleetRoute(pathname: string): boolean {
  return (
    pathname === "/api/claim" ||
    pathname === "/api/claim/release" ||
    pathname.startsWith("/api/connect/") ||
    pathname === "/api/webhook/ci"
  );
}

/**
 * The fleet token from SHIPWRIGHT_FLEET_TOKEN, else the file named by SHIPWRIGHT_FLEET_TOKEN_FILE
 * (trimmed). A named file that cannot be read or is empty is an error, never "no token".
 */
export function readFleetToken(
  env: Env,
  readFile: (path: string) => string,
): { token: string; error?: undefined } | { token?: undefined; error: string } {
  if (env.SHIPWRIGHT_FLEET_TOKEN) return { token: env.SHIPWRIGHT_FLEET_TOKEN };
  const path = env.SHIPWRIGHT_FLEET_TOKEN_FILE;
  if (!path) return { token: "" };
  let token: string;
  try {
    token = readFile(path).trim();
  } catch {
    return { error: `cannot read SHIPWRIGHT_FLEET_TOKEN_FILE (${path})` };
  }
  return token ? { token } : { error: `SHIPWRIGHT_FLEET_TOKEN_FILE (${path}) is empty` };
}

export function loadGuardConfig(env: Env, host: string, port: number): GuardConfig {
  const extra = (env.SW_DASHBOARD_ORIGINS ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter((o) => o.length > 0 && o !== "*");
  return {
    fleetToken: env.SHIPWRIGHT_FLEET_TOKEN ?? "",
    host,
    allowedOrigins: [`http://localhost:${port}`, `http://127.0.0.1:${port}`, ...extra],
  };
}

/** Why the server must not start with this config, or null. auth=none is loopback-only. */
export function startupProblem(cfg: GuardConfig, authEnabled: boolean): string | null {
  if (isLoopbackHost(cfg.host)) return null;
  if (!authEnabled) {
    return `refusing to bind ${cfg.host} with auth=none: configure GITHUB_PAT + DASHBOARD_REPO (or OAuth), or bind 127.0.0.1`;
  }
  if (!cfg.fleetToken) {
    return `refusing to bind ${cfg.host} without SHIPWRIGHT_FLEET_TOKEN (or SHIPWRIGHT_FLEET_TOKEN_FILE): /api/claim, /api/connect/* and /api/webhook/ci would be unauthenticated`;
  }
  return null;
}

/** The token a fleet worker presented: `X-Shipwright-Token`, else `Authorization: Bearer`. */
export function presentedToken(req: Request): string | null {
  const header = req.headers.get(TOKEN_HEADER);
  if (header) return header;
  const auth = req.headers.get("authorization") ?? "";
  return auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : null;
}

/** Constant-time comparison so response timing does not leak the token. Empty never matches. */
export function tokenMatches(expected: string, given: string | null): boolean {
  if (!expected || given === null || given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

const reject = (status: number, error: string): Response =>
  new Response(JSON.stringify({ error }), {
    status,
    headers: { "Content-Type": "application/json" },
  });

function isJson(req: Request): boolean {
  const type = (req.headers.get("content-type") ?? "").split(";")[0] ?? "";
  return type.trim().toLowerCase() === "application/json";
}

function fleetAuth(req: Request, cfg: GuardConfig, hasSession: boolean): Response | null {
  if (hasSession) return null; // a signed-in dashboard user (team view claim/release)
  if (!cfg.fleetToken && isLoopbackHost(cfg.host)) return null;
  // One opaque answer for "no token configured", "missing" and "wrong".
  return tokenMatches(cfg.fleetToken, presentedToken(req)) ? null : reject(401, "unauthorized");
}

/**
 * A rejection, or null when the request may be routed. A preflight or mutating request that names
 * an origin must name an allowed one. Mutating requests must be JSON (so a cross-site form cannot
 * post without a CORS preflight); the login form under /auth/ is exempt. Fleet routes need the
 * fleet token or a signed-in session, except on loopback with no token configured.
 * `hasSession`: auth is enabled and the request carries a valid session.
 */
export function guardRequest(req: Request, cfg: GuardConfig, hasSession: boolean): Response | null {
  const { pathname } = new URL(req.url);
  if (req.method === "OPTIONS" || MUTATING.has(req.method)) {
    const origin = req.headers.get("origin");
    if (origin !== null && !cfg.allowedOrigins.includes(origin)) {
      return reject(403, "origin not allowed");
    }
  }
  if (MUTATING.has(req.method) && !pathname.startsWith("/auth/") && !isJson(req)) {
    return reject(415, "mutating requests must be application/json");
  }
  return isFleetRoute(pathname) ? fleetAuth(req, cfg, hasSession) : null;
}

/** Adds `Access-Control-Allow-Origin` for allowed origins only (never `*`). */
export function withCors(
  res: Response | undefined,
  req: Request,
  cfg: GuardConfig,
): Response | undefined {
  const origin = req.headers.get("origin");
  if (!res || origin === null || !cfg.allowedOrigins.includes(origin)) return res;
  const out = new Response(res.body, res);
  out.headers.set("Access-Control-Allow-Origin", origin);
  out.headers.append("Vary", "Origin");
  return out;
}
