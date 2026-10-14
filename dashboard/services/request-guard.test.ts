// @vitest-environment node
// (happy-dom drops the Origin header, which these tests need.)
import { describe, expect, it } from "vitest";
import {
  type GuardConfig,
  guardRequest,
  isFleetRoute,
  loadGuardConfig,
  presentedToken,
  readFleetToken,
  sessionCookieAttributes,
  startupProblem,
  tokenMatches,
  withCors,
  wsOriginAllowed,
} from "./request-guard";

const LOCAL = "http://localhost:8767";
const JSON_CT = { "Content-Type": "application/json" };
const cfg = (over: Partial<GuardConfig> = {}): GuardConfig => ({
  fleetToken: "",
  host: "127.0.0.1",
  allowedOrigins: [LOCAL],
  allowedHosts: ["localhost", "127.0.0.1", "[::1]"],
  secureCookie: false,
  ...over,
});
const req = (
  method: string,
  path: string,
  headers: Record<string, string> = {},
  base = "http://127.0.0.1:8767",
) =>
  new Request(`${base}${path}`, {
    method,
    headers,
    body: method === "GET" || method === "OPTIONS" ? undefined : "{}",
  });
const guard = (r: Request, c: GuardConfig = cfg(), hasSession = false) =>
  guardRequest(r, c, hasSession);

describe("loadGuardConfig", () => {
  it("allows the local origins plus SW_DASHBOARD_ORIGINS", () => {
    const c = loadGuardConfig(
      { SHIPWRIGHT_FLEET_TOKEN: "t", SW_DASHBOARD_ORIGINS: " https://a.example , " },
      "0.0.0.0",
      9000,
    );
    expect(c).toEqual({
      fleetToken: "t",
      host: "0.0.0.0",
      allowedOrigins: [
        "http://localhost:9000",
        "http://127.0.0.1:9000",
        "http://[::1]:9000",
        "https://a.example",
      ],
      allowedHosts: ["localhost", "127.0.0.1", "[::1]", "a.example"],
      secureCookie: true,
    });
  });
  it("trims the env token", () => {
    expect(loadGuardConfig({ SHIPWRIGHT_FLEET_TOKEN: " t \n" }, "127.0.0.1", 1).fleetToken).toBe(
      "t",
    );
  });
  it("sets secureCookie only for an https origin or SW_DASHBOARD_SECURE_COOKIE=1", () => {
    expect(loadGuardConfig({}, "127.0.0.1", 1).secureCookie).toBe(false);
    expect(loadGuardConfig({ SW_DASHBOARD_SECURE_COOKIE: "1" }, "127.0.0.1", 1).secureCookie).toBe(
      true,
    );
    const http = loadGuardConfig({ SW_DASHBOARD_ORIGINS: "http://box:1" }, "127.0.0.1", 1);
    expect(http.secureCookie).toBe(false);
  });
  it("never allowlists the * wildcard", () => {
    const c = loadGuardConfig({ SW_DASHBOARD_ORIGINS: "*,https://a.example" }, "127.0.0.1", 9000);
    expect(c.allowedOrigins).not.toContain("*");
  });
});

describe("readFleetToken", () => {
  const files: Record<string, string> = { "/etc/sw/token": "  filetok\n" };
  const read = (p: string): string => {
    const v = files[p];
    if (v === undefined) throw new Error("ENOENT");
    return v;
  };
  it("trims SHIPWRIGHT_FLEET_TOKEN and falls back to the file when it is blank", () => {
    expect(readFleetToken({ SHIPWRIGHT_FLEET_TOKEN: " envtok\n" }, read)).toEqual({
      token: "envtok",
    });
    const blank = { SHIPWRIGHT_FLEET_TOKEN: "  ", SHIPWRIGHT_FLEET_TOKEN_FILE: "/etc/sw/token" };
    expect(readFleetToken(blank, read)).toEqual({ token: "filetok" });
  });
  it("prefers SHIPWRIGHT_FLEET_TOKEN", () => {
    const env = { SHIPWRIGHT_FLEET_TOKEN: "envtok", SHIPWRIGHT_FLEET_TOKEN_FILE: "/etc/sw/token" };
    expect(readFleetToken(env, read)).toEqual({ token: "envtok" });
  });
  it("reads and trims SHIPWRIGHT_FLEET_TOKEN_FILE", () => {
    expect(readFleetToken({ SHIPWRIGHT_FLEET_TOKEN_FILE: "/etc/sw/token" }, read)).toEqual({
      token: "filetok",
    });
  });
  it("fails closed on an unreadable or empty token file", () => {
    const missing = readFleetToken({ SHIPWRIGHT_FLEET_TOKEN_FILE: "/nope" }, read);
    expect(missing.error).toMatch(/SHIPWRIGHT_FLEET_TOKEN_FILE/);
    const empty = readFleetToken({ SHIPWRIGHT_FLEET_TOKEN_FILE: "/e" }, () => " \n");
    expect(empty.error).toMatch(/empty/);
  });
  it("returns an empty token when neither is set", () => {
    expect(readFleetToken({}, read)).toEqual({ token: "" });
  });
});

describe("startupProblem", () => {
  it("allows anything on loopback", () => {
    expect(startupProblem(cfg(), false)).toBeNull();
    expect(startupProblem(cfg({ host: "::1" }), false)).toBeNull();
  });
  it("refuses auth=none on a public address", () => {
    expect(startupProblem(cfg({ host: "0.0.0.0" }), false)).toMatch(/auth=none/);
  });
  it("refuses a public address without a fleet token", () => {
    expect(startupProblem(cfg({ host: "0.0.0.0" }), true)).toMatch(/SHIPWRIGHT_FLEET_TOKEN/);
  });
  it("accepts a public address with auth and a fleet token", () => {
    expect(startupProblem(cfg({ host: "0.0.0.0", fleetToken: "t" }), true)).toBeNull();
  });
  it("never puts the token in the message", () => {
    const msg = startupProblem(cfg({ host: "0.0.0.0", fleetToken: "s3cret" }), false) ?? "";
    expect(msg).not.toContain("s3cret");
  });
});

describe("guardRequest", () => {
  it("lets GETs through", () => {
    expect(guard(req("GET", "/api/status"))).toBeNull();
  });
  it("rejects a non-JSON POST with 415", () => {
    const r = guard(req("POST", "/api/daemon/pause", { "Content-Type": "text/plain" }));
    expect(r?.status).toBe(415);
  });
  it("rejects a form POST with 415", () => {
    const form = { "Content-Type": "application/x-www-form-urlencoded" };
    expect(guard(req("POST", "/api/daemon/pause", form))?.status).toBe(415);
  });
  it("accepts a JSON POST with a charset parameter", () => {
    const ct = { "Content-Type": "application/json; charset=utf-8" };
    expect(guard(req("POST", "/api/daemon/pause", ct))).toBeNull();
  });
  it("exempts the login form under /auth/", () => {
    const form = { "Content-Type": "application/x-www-form-urlencoded" };
    expect(guard(req("POST", "/auth/pat-login", form))).toBeNull();
  });
  it("rejects a mutating request from a foreign origin with 403", () => {
    const r = guard(req("POST", "/api/daemon/stop", { ...JSON_CT, Origin: "https://evil.example" }));
    expect(r?.status).toBe(403);
  });
  it("rejects a foreign origin even on the /auth/ form", () => {
    const form = { "Content-Type": "application/x-www-form-urlencoded", Origin: "https://e.x" };
    expect(guard(req("POST", "/auth/pat-login", form))?.status).toBe(403);
  });
  it("allows a same-origin mutating request", () => {
    expect(guard(req("POST", "/api/daemon/stop", { ...JSON_CT, Origin: LOCAL }))).toBeNull();
  });
  it("rejects a preflight from a foreign origin and allows one from an allowed origin", () => {
    const foreign = guard(req("OPTIONS", "/api/daemon/stop", { Origin: "https://evil.example" }));
    expect(foreign?.status).toBe(403);
    expect(guard(req("OPTIONS", "/api/daemon/stop", { Origin: LOCAL }))).toBeNull();
  });
  it("allows a fleet route without a token only when none is set on loopback", () => {
    expect(guard(req("POST", "/api/claim", JSON_CT))).toBeNull();
    expect(guard(req("POST", "/api/claim", JSON_CT), cfg({ host: "0.0.0.0" }))?.status).toBe(401);
  });
  it.each(["/api/claim", "/api/claim/release", "/api/connect/heartbeat", "/api/webhook/ci"])(
    "requires the fleet token on %s once one is configured",
    (path) => {
      const c = cfg({ fleetToken: "s3cret" });
      expect(guard(req("POST", path, JSON_CT), c)?.status).toBe(401);
      const wrong = { ...JSON_CT, "X-Shipwright-Token": "nope00" };
      expect(guard(req("POST", path, wrong), c)?.status).toBe(401);
      const right = { ...JSON_CT, "X-Shipwright-Token": "s3cret" };
      expect(guard(req("POST", path, right), c)).toBeNull();
      const bearer = { ...JSON_CT, Authorization: "Bearer s3cret" };
      expect(guard(req("POST", path, bearer), c)).toBeNull();
    },
  );
  it("does not accept the token from the query string", () => {
    const c = cfg({ fleetToken: "s3cret" });
    expect(guard(req("POST", "/api/claim?token=s3cret", JSON_CT), c)?.status).toBe(401);
  });
  it("answers 401 with no detail", async () => {
    const r = guard(req("POST", "/api/claim", JSON_CT), cfg({ fleetToken: "s3cret" }));
    expect(await r?.json()).toEqual({ error: "unauthorized" });
  });
  it("lets a signed-in dashboard session use fleet routes without the token", () => {
    const c = cfg({ host: "0.0.0.0", fleetToken: "s3cret" });
    expect(guard(req("POST", "/api/claim", JSON_CT), c, true)).toBeNull();
  });
});

describe("Host allowlist on loopback (DNS rebinding)", () => {
  const rebound = (method: string, path: string, headers: Record<string, string> = {}) =>
    req(method, path, headers, "http://evil.example:8767");
  it("answers 421 to a foreign Host on a loopback bind, for GET and WebSocket", () => {
    expect(guard(rebound("GET", "/api/status"))?.status).toBe(421);
    expect(guard(rebound("GET", "/ws", { Upgrade: "websocket" }))?.status).toBe(421);
    expect(guard(rebound("POST", "/api/daemon/pause", JSON_CT))?.status).toBe(421);
  });
  it("accepts localhost, 127.0.0.1 and [::1] on any port", () => {
    expect(guard(req("GET", "/api/status", {}, "http://localhost:8767"))).toBeNull();
    expect(guard(req("GET", "/api/status", {}, "http://[::1]:8767"))).toBeNull();
    expect(guard(req("GET", "/api/status"))).toBeNull();
  });
  it("accepts a host named in SW_DASHBOARD_ORIGINS", () => {
    const c = cfg({ allowedHosts: ["localhost", "127.0.0.1", "[::1]", "evil.example"] });
    expect(guard(rebound("GET", "/api/status"), c)).toBeNull();
  });
  it("does not check Host on a public bind", () => {
    const c = cfg({ host: "0.0.0.0", fleetToken: "t" });
    expect(guard(rebound("GET", "/api/status"), c)).toBeNull();
  });
});

describe("WebSocket origin (cross-site WebSocket hijacking)", () => {
  const ws = { Upgrade: "websocket", Connection: "Upgrade" };
  it.each(["/ws", "/ws/events"])("rejects a foreign Origin on %s with 403", (path) => {
    const r = req("GET", path, { ...ws, Origin: "https://evil.example" });
    expect(wsOriginAllowed(r, cfg())).toBe(false);
    expect(guard(r)?.status).toBe(403);
    const pub = cfg({ host: "0.0.0.0", fleetToken: "t" });
    expect(guard(r, pub, true)?.status).toBe(403);
  });
  it.each(["/ws", "/ws/events"])("allows an allowed or loopback Origin on %s", (path) => {
    expect(guard(req("GET", path, { ...ws, Origin: LOCAL }))).toBeNull();
    const c = loadGuardConfig({}, "127.0.0.1", 8767);
    for (const o of ["http://127.0.0.1:8767", "http://[::1]:8767", "http://localhost:8767"]) {
      expect(wsOriginAllowed(req("GET", path, { ...ws, Origin: o }), c)).toBe(true);
    }
    expect(wsOriginAllowed(req("GET", path, { ...ws, Origin: "http://localhost:9999" }), c)).toBe(
      false,
    );
  });
  it("allows a non-browser client with no Origin", () => {
    expect(guard(req("GET", "/ws", ws))).toBeNull();
  });
  it("checks any Upgrade: websocket request, not only /ws paths", () => {
    const r = req("GET", "/anything", { ...ws, Origin: "https://evil.example" });
    expect(guard(r)?.status).toBe(403);
  });
});

describe("logout", () => {
  it("rejects a cross-site logout POST", () => {
    const form = { "Content-Type": "application/x-www-form-urlencoded", Origin: "https://e.x" };
    expect(guard(req("POST", "/auth/logout", form))?.status).toBe(403);
    const same = { "Content-Type": "application/x-www-form-urlencoded", Origin: LOCAL };
    expect(guard(req("POST", "/auth/logout", same))).toBeNull();
  });
});

describe("sessionCookieAttributes", () => {
  it("adds Secure only when configured", () => {
    expect(sessionCookieAttributes(cfg())).toBe("Path=/; HttpOnly; SameSite=Lax");
    expect(sessionCookieAttributes(cfg({ secureCookie: true }))).toBe(
      "Path=/; HttpOnly; SameSite=Lax; Secure",
    );
  });
});

describe("helpers", () => {
  it("classifies fleet routes", () => {
    expect(isFleetRoute("/api/connect/disconnect")).toBe(true);
    expect(isFleetRoute("/api/claims")).toBe(false);
  });
  it("reads the token header before Authorization", () => {
    const r = req("GET", "/", { "X-Shipwright-Token": "a", Authorization: "Bearer b" });
    expect(presentedToken(r)).toBe("a");
    expect(presentedToken(req("GET", "/"))).toBeNull();
  });
  it("accepts the Bearer scheme case-insensitively", () => {
    expect(presentedToken(req("GET", "/", { Authorization: "bearer abc" }))).toBe("abc");
    expect(presentedToken(req("GET", "/", { Authorization: "BEARER  abc" }))).toBe("abc");
    expect(presentedToken(req("GET", "/", { Authorization: "Basic abc" }))).toBeNull();
  });
  it("compares tokens exactly", () => {
    expect(tokenMatches("abc", "abc")).toBe(true);
    expect(tokenMatches("abc", "abd")).toBe(false);
    expect(tokenMatches("abc", "ab")).toBe(false);
    expect(tokenMatches("abc", null)).toBe(false);
    expect(tokenMatches("", "")).toBe(false);
  });
});

describe("withCors", () => {
  it("echoes an allowed origin and never sends *", () => {
    const res = withCors(new Response("ok"), req("GET", "/", { Origin: LOCAL }), cfg());
    expect(res?.headers.get("Access-Control-Allow-Origin")).toBe(LOCAL);
    expect(res?.headers.get("Vary")).toContain("Origin");
  });
  it("adds nothing for a foreign or missing origin", () => {
    const foreign = withCors(new Response("ok"), req("GET", "/", { Origin: "https://x.y" }), cfg());
    expect(foreign?.headers.get("Access-Control-Allow-Origin")).toBeNull();
    const none = withCors(new Response("ok"), req("GET", "/"), cfg());
    expect(none?.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });
  it("passes a WebSocket upgrade (undefined) through", () => {
    expect(withCors(undefined, req("GET", "/ws", { Origin: LOCAL }), cfg())).toBeUndefined();
  });
});
