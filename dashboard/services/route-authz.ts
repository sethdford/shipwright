// Server-side role authorization for every state-changing dashboard route (#8720).
//
// The client gate (core/guard.ts) only hides buttons. This module is the authorization: one
// check, run for every request before routing. Deny by default: any method other than GET, HEAD
// or OPTIONS is mutating, and a mutating route that is not in MUTATING_ROUTES or PUBLIC_MUTATIONS
// needs the highest permission (admin only). The enumeration test in route-authz.test.ts fails
// when server.ts or routes/ gain a mutating route that is not classified here.
//
// Auth-off local mode (no OAuth or PAT configured) is single-user: the request guard only allows
// it on a loopback bind, and every caller is the local operator, so no role check applies.

export type Role = "viewer" | "operator" | "admin";

export type Permission =
  | "read"
  | "intervene"
  | "approve"
  | "control-daemon"
  | "configure"
  | "manage-users";

export const ROLE_PERMISSIONS: Readonly<Record<Role, ReadonlySet<Permission>>> = {
  viewer: new Set<Permission>(["read"]),
  operator: new Set<Permission>(["read", "intervene", "approve", "control-daemon"]),
  admin: new Set<Permission>([
    "read",
    "intervene",
    "approve",
    "control-daemon",
    "configure",
    "manage-users",
  ]),
};

/** The permission an unclassified mutating route needs: deny by default, admin only. */
export const UNCLASSIFIED_PERMISSION: Permission = "manage-users";

const READ_METHODS: ReadonlySet<string> = new Set(["GET", "HEAD", "OPTIONS"]);

export interface RouteRule {
  readonly method: string;
  readonly pattern: RegExp;
  readonly permission: Permission;
}

const rule = (method: string, pattern: RegExp, permission: Permission): RouteRule => ({
  method,
  pattern,
  permission,
});

/** Every mutating route the server handles, with the permission it needs. */
export const MUTATING_ROUTES: readonly RouteRule[] = [
  // Run interventions: abort, pause, resume, skip, message, bulk.
  rule("POST", /^\/api\/intervention\/bulk$/, "intervene"),
  rule("POST", /^\/api\/intervention\/[^/]+(\/[^/]+)?$/, "intervene"),
  rule("POST", /^\/api\/claim$/, "intervene"),
  rule("POST", /^\/api\/claim\/release$/, "intervene"),
  // Daemon control.
  rule("POST", /^\/api\/emergency-brake$/, "control-daemon"),
  rule("POST", /^\/api\/daemon\/(start|stop|pause|resume|patrol)$/, "control-daemon"),
  rule("POST", /^\/api\/machines\/[^/]+\/health-check$/, "control-daemon"),
  // Approvals.
  rule("POST", /^\/api\/approval-gates\/\d+\/(approve|reject)$/, "approve"),
  // Configuration.
  rule("POST", /^\/api\/machines$/, "configure"),
  rule("PATCH", /^\/api\/machines\/[^/]+$/, "configure"),
  rule("DELETE", /^\/api\/machines\/[^/]+$/, "configure"),
  rule("POST", /^\/api\/notifications\/(config|webhook|test)$/, "configure"),
  rule("DELETE", /^\/api\/notifications\/webhook$/, "configure"),
  rule("POST", /^\/api\/approval-gates$/, "configure"),
  rule("POST", /^\/api\/quality-gates$/, "configure"),
  // Fleet worker presence and CI webhooks: workers use the fleet token. A browser session
  // never needs these, so a session caller must be an admin.
  rule("POST", /^\/api\/connect\/(heartbeat|disconnect)$/, "configure"),
  rule("POST", /^\/api\/webhook\/ci$/, "configure"),
  // Users and access.
  rule("POST", /^\/api\/rbac$/, "manage-users"),
  rule("POST", /^\/api\/join-token$/, "manage-users"),
  rule("POST", /^\/api\/team\/invite$/, "manage-users"),
];

/**
 * Mutating routes that carry their own credential and are reached before sign-in: the login
 * form, logout, and join/invite redemption (an invite or join token in a header). Anything else
 * that mutates needs a session with the right role.
 */
export const PUBLIC_MUTATIONS: readonly RouteRule[] = [
  rule("POST", /^\/auth\/pat-login$/, "read"),
  rule("POST", /^\/auth\/logout$/, "read"),
  rule("POST", /^\/api\/join$/, "read"),
  rule("POST", /^\/api\/team\/invite\/verify$/, "read"),
];

const matches = (rules: readonly RouteRule[], method: string, pathname: string) =>
  rules.find((r) => r.method === method && r.pattern.test(pathname));

export type Classification =
  | { kind: "read" }
  | { kind: "public" }
  | { kind: "mutating"; permission: Permission; classified: boolean };

/** How a request is classified. Unknown mutating routes are admin-only (`classified: false`). */
export function classifyRoute(method: string, pathname: string): Classification {
  const m = method.toUpperCase();
  if (READ_METHODS.has(m)) return { kind: "read" };
  if (matches(PUBLIC_MUTATIONS, m, pathname)) return { kind: "public" };
  const known = matches(MUTATING_ROUTES, m, pathname);
  if (known) return { kind: "mutating", permission: known.permission, classified: true };
  return { kind: "mutating", permission: UNCLASSIFIED_PERMISSION, classified: false };
}

/** A role from untrusted state (sessions.json, rbac.json). Anything unknown is null. */
export function normalizeRole(value: unknown): Role | null {
  return value === "viewer" || value === "operator" || value === "admin" ? value : null;
}

export function roleHasPermission(role: Role | null, permission: Permission): boolean {
  if (role === null) return false;
  return ROLE_PERMISSIONS[role].has(permission);
}

export interface AuthzContext {
  /** OAuth or PAT auth is configured. Off means single-user local mode. */
  readonly authEnabled: boolean;
  /** The caller presented the correct fleet token (a worker, not a browser). */
  readonly fleetTokenValid: boolean;
  /** The signed-in session's role, or undefined when there is no session. */
  readonly sessionRole: unknown;
}

/** The stable 403 body. The client gate reads `code` and surfaces `required`. */
export function forbidden(required: Permission): Response {
  return new Response(JSON.stringify({ error: "forbidden", code: "role_forbidden", required }), {
    status: 403,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

/** Null when the request may be routed, else a 403. Run before any route handler. */
export function authorizeRequest(req: Request, ctx: AuthzContext): Response | null {
  if (!ctx.authEnabled) return null;
  let pathname: string;
  try {
    pathname = new URL(req.url).pathname;
  } catch {
    return forbidden(UNCLASSIFIED_PERMISSION);
  }
  const c = classifyRoute(req.method, pathname);
  if (c.kind !== "mutating") return null;
  if (ctx.fleetTokenValid && isFleetMutation(pathname)) return null;
  if (roleHasPermission(normalizeRole(ctx.sessionRole), c.permission)) return null;
  return forbidden(c.permission);
}

/** Routes a fleet worker calls with the fleet token instead of a session. */
function isFleetMutation(pathname: string): boolean {
  return (
    pathname === "/api/claim" ||
    pathname === "/api/claim/release" ||
    pathname === "/api/connect/heartbeat" ||
    pathname === "/api/connect/disconnect" ||
    pathname === "/api/webhook/ci"
  );
}
