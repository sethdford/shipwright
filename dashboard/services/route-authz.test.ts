// @vitest-environment node
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  type AuthzContext,
  authorizeRequest,
  classifyRoute,
  MUTATING_ROUTES,
  normalizeRole,
  PUBLIC_MUTATIONS,
  ROLE_PERMISSIONS,
  UNCLASSIFIED_PERMISSION,
} from "./route-authz";

const DASHBOARD = join(__dirname, "..");
const SOURCES = ["server.ts", "routes/join.ts"];
const MUTATING = /req\.method === "(POST|PUT|PATCH|DELETE)"/g;

/** A concrete path that a route regex matches: \d+ becomes 1, [^/]+ becomes x. */
function samplePath(source: string): string {
  return source
    .replace(/^\^/, "")
    .replace(/\$$/, "")
    .replace(/\((?:\?:)?[^)]*\)\?/g, "")
    .replace(/\((?:\?:)?([^|)]+)\|[^)]*\)/g, "$1")
    .replace(/\\d\+/g, "1")
    .replace(/\[\^\/\]\+/g, "x")
    .replace(/\\\//g, "/");
}

interface Found {
  file: string;
  method: string;
  path: string;
}

/** Every mutating route condition in the server sources, as (method, sample path). */
function enumerateMutatingRoutes(): Found[] {
  const found: Found[] = [];
  for (const file of SOURCES) {
    const src = readFileSync(join(DASHBOARD, file), "utf-8");
    for (const m of src.matchAll(MUTATING)) {
      // The path is in the same condition, or in the enclosing `if (pathname ...)` block.
      let start = src.lastIndexOf("if (", m.index);
      let cond = src.slice(start, src.indexOf("{", m.index));
      let path = pathFromCondition(cond);
      for (let hops = 0; path === null && hops < 3 && start > 0; hops++) {
        start = src.lastIndexOf("if (", start - 1);
        cond = src.slice(start, src.indexOf("{", start));
        path = pathFromCondition(cond);
      }
      if (path === null) throw new Error(`${file}: cannot read the route in: ${cond}`);
      found.push({ file, method: m[1], path });
    }
  }
  return found;
}

function pathFromCondition(cond: string): string | null {
  const exact = cond.match(/pathname === "([^"]+)"/);
  if (exact) return exact[1];
  const prefix = cond.match(/pathname\.startsWith\("([^"]+)"\)/);
  if (prefix) return `${prefix[1]}x`;
  const re = cond.match(/pathname\.match\(\/(.+?)\/\)/) ?? cond.match(/\/(\^.+?\$)\/\.test\(pathname\)/);
  return re ? samplePath(re[1]) : null;
}

const ctx = (sessionRole: unknown, over: Partial<AuthzContext> = {}): AuthzContext => ({
  authEnabled: true,
  fleetTokenValid: false,
  sessionRole,
  ...over,
});
const request = (method: string, path: string) =>
  new Request(`http://127.0.0.1:8767${path}`, {
    method,
    body: method === "GET" || method === "HEAD" ? undefined : "{}",
  });

const ROUTE_SAMPLES = MUTATING_ROUTES.map((r) => ({
  ...r,
  path: samplePath(r.pattern.source),
}));

describe("route classification (enumeration)", () => {
  const routes = enumerateMutatingRoutes();

  it("finds the server's mutating routes", () => {
    expect(routes.length).toBeGreaterThanOrEqual(30);
  });

  it.each(routes.map((r) => [`${r.method} ${r.path}`, r]))(
    "%s is classified explicitly",
    (_label, r) => {
      const c = classifyRoute(r.method, r.path);
      const known = c.kind === "public" || (c.kind === "mutating" && c.classified);
      expect(known, `${r.file}: add ${r.method} ${r.path} to MUTATING_ROUTES or PUBLIC_MUTATIONS`).toBe(true);
    },
  );

  it("every rule's sample path matches its own rule", () => {
    for (const r of ROUTE_SAMPLES) {
      expect(classifyRoute(r.method, r.path)).toEqual({
        kind: "mutating",
        permission: r.permission,
        classified: true,
      });
    }
  });

  it("an unknown mutating route is admin-only (deny by default)", () => {
    expect(classifyRoute("POST", "/api/brand-new")).toEqual({
      kind: "mutating",
      permission: UNCLASSIFIED_PERMISSION,
      classified: false,
    });
    expect(ROLE_PERMISSIONS.operator.has(UNCLASSIFIED_PERMISSION)).toBe(false);
  });

  it("reads are never mutating", () => {
    for (const m of ["GET", "HEAD", "OPTIONS", "get"]) {
      expect(classifyRoute(m, "/api/daemon/stop").kind).toBe("read");
    }
  });
});

describe("authorizeRequest", () => {
  it.each(ROUTE_SAMPLES.map((r) => [`${r.method} ${r.path}`, r]))(
    "%s: viewer, unauthenticated and missing or unknown roles get 403",
    async (_label, r) => {
      for (const role of ["viewer", undefined, null, "", "root", 7]) {
        const res = authorizeRequest(request(r.method, r.path), ctx(role));
        expect(res?.status).toBe(403);
        expect(await res?.json()).toEqual({
          error: "forbidden",
          code: "role_forbidden",
          required: r.permission,
        });
      }
    },
  );

  it.each(ROUTE_SAMPLES.map((r) => [`${r.method} ${r.path}`, r]))(
    "%s: admin passes; operator passes only with the permission",
    (_label, r) => {
      expect(authorizeRequest(request(r.method, r.path), ctx("admin"))).toBeNull();
      const operatorOk = ROLE_PERMISSIONS.operator.has(r.permission);
      const res = authorizeRequest(request(r.method, r.path), ctx("operator"));
      expect(res === null).toBe(operatorOk);
    },
  );

  it("operators can intervene, approve and control the daemon, not configure", () => {
    const op = (m: string, p: string) => authorizeRequest(request(m, p), ctx("operator"));
    expect(op("POST", "/api/intervention/12/abort")).toBeNull();
    expect(op("POST", "/api/approval-gates/12/approve")).toBeNull();
    expect(op("POST", "/api/daemon/stop")).toBeNull();
    expect(op("POST", "/api/rbac")?.status).toBe(403);
    expect(op("POST", "/api/notifications/webhook")?.status).toBe(403);
    expect(op("DELETE", "/api/machines/m1")?.status).toBe(403);
  });

  it("an unclassified mutating route needs admin", () => {
    expect(authorizeRequest(request("POST", "/api/new-thing"), ctx("operator"))?.status).toBe(403);
    expect(authorizeRequest(request("POST", "/api/new-thing"), ctx("admin"))).toBeNull();
    expect(authorizeRequest(request("POST", "/api/intervention/1/abort/extra"), ctx("operator"))?.status).toBe(403);
  });

  it("reads pass for any session state (the auth gate handles sign-in)", () => {
    expect(authorizeRequest(request("GET", "/api/status"), ctx(undefined))).toBeNull();
  });

  it("public mutations (login, logout, join, invite verify) skip the role check", () => {
    for (const r of PUBLIC_MUTATIONS) {
      const path = samplePath(r.pattern.source);
      expect(authorizeRequest(request(r.method, path), ctx(undefined))).toBeNull();
    }
  });

  it("a valid fleet token passes on fleet routes only", () => {
    const fleet = ctx(undefined, { fleetTokenValid: true });
    for (const p of ["/api/claim", "/api/claim/release", "/api/connect/heartbeat", "/api/webhook/ci"]) {
      expect(authorizeRequest(request("POST", p), fleet)).toBeNull();
    }
    expect(authorizeRequest(request("POST", "/api/daemon/stop"), fleet)?.status).toBe(403);
    expect(authorizeRequest(request("POST", "/api/rbac"), fleet)?.status).toBe(403);
  });

  it("a viewer session cannot claim issues", () => {
    expect(authorizeRequest(request("POST", "/api/claim"), ctx("viewer"))?.status).toBe(403);
    expect(authorizeRequest(request("POST", "/api/claim"), ctx("operator"))).toBeNull();
  });

  it("auth-off local mode (single user) is unchanged", () => {
    const off = ctx(undefined, { authEnabled: false });
    for (const r of ROUTE_SAMPLES) {
      expect(authorizeRequest(request(r.method, r.path), off)).toBeNull();
    }
  });
});

describe("normalizeRole", () => {
  it("accepts only the three roles", () => {
    expect(normalizeRole("viewer")).toBe("viewer");
    expect(normalizeRole("operator")).toBe("operator");
    expect(normalizeRole("admin")).toBe("admin");
    for (const v of ["Admin", "", undefined, null, 1, {}]) expect(normalizeRole(v)).toBeNull();
  });
});
