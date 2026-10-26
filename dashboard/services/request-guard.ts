// Request guard for the dashboard (spec §6.2 "Dashboard exposure", #8534).
// Pure: no environment reads and no I/O (node:crypto is used only for hashing). server.ts builds the config at startup and calls
// guardRequest() before any route and withCors() on every response.
//
// Who authenticates how:
// - Browser UI: the existing `fleet_session` cookie (HttpOnly, SameSite=Lax) set after GitHub
//   OAuth or PAT login. The browser never holds the fleet token; WebSockets use the same cookie.
// - Fleet workers (claim, connect, CI webhook): `X-Shipwright-Token` (or `Authorization: Bearer`)
//   matching SHIPWRIGHT_FLEET_TOKEN / SHIPWRIGHT_FLEET_TOKEN_FILE. Never a query parameter.
// - auth=none (no OAuth/PAT configured) is allowed only on a loopback bind.
// - On a loopback bind the Host header must name a loopback host (or one from
//   SW_DASHBOARD_ORIGINS): DNS rebinding gets 421. WebSocket upgrades from a foreign Origin get 403.

import { createHash, timingSafeEqual } from "node:crypto";
import { mutableResponse } from "./security-headers";

export interface GuardConfig {
  /** Shared fleet token (SHIPWRIGHT_FLEET_TOKEN). Empty when none is configured. */
  readonly fleetToken: string;
  /** Address the server binds to. */
  readonly host: string;
  /** Exact origins allowed for CORS and for mutating browser requests. */
  readonly allowedOrigins: readonly string[];
  /** Hostnames (with IPv6 brackets) a loopback-bound server answers to. */
  readonly allowedHosts: readonly string[];
  /** Mark the session cookie Secure (an https origin is allowed, or SW_DASHBOARD_SECURE_COOKIE=1). */
  readonly secureCookie: boolean;
}

type Env = Readonly<Record<string, string | undefined>>;

export const TOKEN_HEADER = "x-shipwright-token";
const MUTATING = new Set(["POST", "PUT", "PATCH", "DELETE"]);
const LOOPBACK = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);
const LOOPBACK_HOSTNAMES = ["localhost", "127.0.0.1", "[::1]"];

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
  const fromEnv = (env.SHIPWRIGHT_FLEET_TOKEN ?? "").trim();
  if (fromEnv) return { token: fromEnv };
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
  // Normalized with new URL(o).origin: lowercase host, default port dropped, path removed.
  // Entries that are not http(s) URLs (including "*") are dropped.
  const extra: string[] = [];
  const extraHosts: string[] = [];
  for (const raw of (env.SW_DASHBOARD_ORIGINS ?? "").split(",")) {
    let url: URL;
    try {
      url = new URL(raw.trim());
    } catch {
      continue;
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") continue;
    if (!extra.includes(url.origin)) extra.push(url.origin);
    if (!extraHosts.includes(url.hostname)) extraHosts.push(url.hostname);
  }
  return {
    fleetToken: (env.SHIPWRIGHT_FLEET_TOKEN ?? "").trim(),
    host,
    allowedOrigins: [
      `http://localhost:${port}`,
      `http://127.0.0.1:${port}`,
      `http://[::1]:${port}`,
      ...extra,
    ],
    allowedHosts: [...LOOPBACK_HOSTNAMES, ...extraHosts],
    secureCookie:
      env.SW_DASHBOARD_SECURE_COOKIE === "1" || extra.some((o) => o.startsWith("https://")),
  };
}

/** Attributes for the `fleet_session` cookie (without Max-Age). */
export function sessionCookieAttributes(cfg: GuardConfig): string {
  return `Path=/; HttpOnly; SameSite=Lax${cfg.secureCookie ? "; Secure" : ""}`;
}

/**
 * Whether the dashboard is reachable from beyond this machine: bound to a non-loopback address,
 * or loopback behind a proxy (SW_DASHBOARD_ORIGINS names a non-loopback host).
 */
export function isExposed(cfg: GuardConfig): boolean {
  return (
    !isLoopbackHost(cfg.host) || cfg.allowedHosts.some((h) => !LOOPBACK_HOSTNAMES.includes(h))
  );
}

/** Why the server must not start with this config, or null. auth=none is local-only. */
export function startupProblem(cfg: GuardConfig, authEnabled: boolean): string | null {
  if (!isExposed(cfg)) return null;
  const where = isLoopbackHost(cfg.host)
    ? `${cfg.host} behind a proxy (SW_DASHBOARD_ORIGINS names a non-loopback host)`
    : cfg.host;
  if (!authEnabled) {
    return `refusing to serve ${where} with auth=none: configure GITHUB_PAT + DASHBOARD_REPO (or OAuth), or bind 127.0.0.1 with no public origins`;
  }
  if (!cfg.fleetToken) {
    return `refusing to serve ${where} without SHIPWRIGHT_FLEET_TOKEN (or SHIPWRIGHT_FLEET_TOKEN_FILE): /api/claim, /api/connect/* and /api/webhook/ci would be unauthenticated`;
  }
  return null;
}

/** The token a fleet worker presented: `X-Shipwright-Token`, else `Authorization: Bearer`. */
export function presentedToken(req: Request): string | null {
  const header = req.headers.get(TOKEN_HEADER);
  if (header) return header;
  const match = /^bearer\s+(\S+)\s*$/i.exec(req.headers.get("authorization") ?? "");
  return match?.[1] ?? null;
}

const sha256 = (s: string): Buffer => createHash("sha256").update(s, "utf8").digest();

/**
 * Compares SHA-256 digests with timingSafeEqual: constant time, and the fixed digest length
 * means the token's length does not leak either. Empty never matches.
 */
export function tokenMatches(expected: string, given: string | null): boolean {
  if (!expected || given === null) return false;
  return timingSafeEqual(sha256(expected), sha256(given));
}

const HOST_HEADER = /^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\])(?::\d{1,5})?$/;

/** The hostname in a Host header (lowercased, IPv6 in brackets), or null when malformed. */
export function parseHostHeader(host: string): string | null {
  if (!HOST_HEADER.test(host)) return null;
  try {
    return new URL(`http://${host}`).hostname.toLowerCase();
  } catch {
    return null;
  }
}

/** The request's hostname from the Host header (else the URL); null when the Host is malformed. */
function requestHostname(req: Request): string | null {
  const host = req.headers.get("host");
  if (host !== null) return parseHostHeader(host);
  try {
    return new URL(req.url).hostname.toLowerCase();
  } catch {
    return null;
  }
}

/** Whether the request names a loopback host (localhost, 127.0.0.1, [::1]) exactly. */
export function isLoopbackRequest(req: Request): boolean {
  const name = requestHostname(req);
  return name !== null && LOOPBACK_HOSTNAMES.includes(name);
}

function isWebSocketUpgrade(req: Request, pathname: string): boolean {
  return (
    (req.headers.get("upgrade") ?? "").toLowerCase() === "websocket" ||
    pathname === "/ws" ||
    pathname === "/ws/events"
  );
}

/**
 * Whether a WebSocket upgrade may proceed: browsers always send Origin on a WebSocket handshake, so
 * a present Origin must be allowlisted (the loopback origins on the bound port are). No Origin
 * means a non-browser client, which the session/loopback checks in server.ts govern.
 */
export function wsOriginAllowed(req: Request, cfg: GuardConfig): boolean {
  const origin = req.headers.get("origin");
  return origin === null || cfg.allowedOrigins.includes(origin);
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

/** Fetch metadata: only same-origin, none (typed URL, bookmark) or no header (curl, workers). */
const FETCH_SITE_OK = new Set(["same-origin", "none"]);

function isCrossSiteToSensitive(req: Request, pathname: string): boolean {
  const site = req.headers.get("sec-fetch-site");
  if (site === null || FETCH_SITE_OK.has(site.toLowerCase())) return false;
  if (pathname === "/auth/callback") return false; // top-level navigation back from github.com
  return (
    pathname.startsWith("/api/") ||
    pathname === "/ws" ||
    pathname.startsWith("/ws/") ||
    pathname.startsWith("/auth/")
  );
}

function fleetAuth(req: Request, cfg: GuardConfig, hasSession: boolean): Response | null {
  if (hasSession) return null; // a signed-in dashboard user (team view claim/release)
  if (!cfg.fleetToken && !isExposed(cfg)) return null;
  // One opaque answer for "no token configured", "missing" and "wrong".
  return tokenMatches(cfg.fleetToken, presentedToken(req)) ? null : reject(401, "unauthorized");
}

/**
 * A rejection, or null when the request may be routed. A malformed Host is 400. On a loopback
 * bind the Host must be an allowed host (421 otherwise: DNS rebinding). A browser request to
 * /api, /ws or /auth whose Sec-Fetch-Site is not same-origin or none is 403 (the OAuth callback
 * excepted). A WebSocket upgrade with a foreign Origin is 403. A preflight or mutating request
 * that names an origin must name an allowed one. Mutating requests must be JSON (so a cross-site form cannot
 * post without a CORS preflight); the login form under /auth/ is exempt. Fleet routes need the
 * fleet token or a signed-in session, except when not exposed (see isExposed) and no token is set.
 * `hasSession`: auth is enabled and the request carries a valid session.
 */
export function guardRequest(req: Request, cfg: GuardConfig, hasSession: boolean): Response | null {
  // Host first: Bun builds req.url from it, so a malformed Host makes the URL unparseable.
  const hostname = requestHostname(req);
  if (hostname === null) return reject(400, "bad host");
  let pathname: string;
  try {
    pathname = new URL(req.url).pathname;
  } catch {
    return reject(400, "bad request");
  }
  if (isLoopbackHost(cfg.host) && !cfg.allowedHosts.includes(hostname)) {
    return reject(421, "misdirected request");
  }
  if (isCrossSiteToSensitive(req, pathname)) return reject(403, "cross-site request");
  if (isWebSocketUpgrade(req, pathname) && !wsOriginAllowed(req, cfg)) {
    return reject(403, "origin not allowed");
  }
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
  const out = mutableResponse(res);
  out.headers.set("Access-Control-Allow-Origin", origin);
  out.headers.append("Vary", "Origin");
  return out;
}
