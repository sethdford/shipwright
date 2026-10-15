// @vitest-environment node
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  type JoinRouteDeps,
  type JoinTokenRecord,
  generateJoinScript,
  handleJoinRoutes,
  joinCommand,
  teamJoinCommand,
} from "./join";

const BASE = "http://dash.test";
const JOIN_TOKEN = "join-tok-7f3a9c";
const INVITE_TOKEN = "invite-tok-9b21e4";

/** In-memory deps: the route module does no file I/O, so these tests never touch a real HOME. */
function makeDeps(opts: { expiredInvite?: boolean } = {}) {
  const tokens: JoinTokenRecord[] = [
    { token: JOIN_TOKEN, label: "rack-1", max_workers: 2, used: false },
  ];
  const expires = opts.expiredInvite
    ? new Date(Date.now() - 1000).toISOString()
    : new Date(Date.now() + 3_600_000).toISOString();
  const invites = new Map<string, { expires_at: string }>([[INVITE_TOKEN, { expires_at: expires }]]);
  const saves: number[] = [];
  const deps: JoinRouteDeps = {
    dashboardUrl: BASE,
    loadJoinTokens: () => tokens,
    saveJoinTokens: (t) => {
      saves.push(t.length);
      tokens.splice(0, tokens.length, ...t);
    },
    lookupInvite: (token) => {
      const e = invites.get(token);
      if (!e || new Date(e.expires_at).getTime() < Date.now()) return undefined;
      return e;
    },
  };
  return { deps, tokens, saves };
}

/** Routes one request through the module; a null result means the module did not handle it. */
function call(
  method: string,
  path: string,
  deps: JoinRouteDeps,
  headers: Record<string, string> = {},
): Response {
  const req = new Request(`${BASE}${path}`, { method, headers });
  const res = handleJoinRoutes(req, new URL(req.url).pathname, deps);
  if (!res) throw new Error(`not routed: ${method} ${path}`);
  return res;
}

const joinHeader = { "X-Shipwright-Join-Token": JOIN_TOKEN, "Content-Type": "application/json" };
const inviteHeader = { "X-Shipwright-Invite-Token": INVITE_TOKEN, "Content-Type": "application/json" };

describe("retired path forms", () => {
  it("refuses GET /api/join/<token> with 410 and does not redeem the token", async () => {
    const { deps, tokens, saves } = makeDeps();
    const res = call("GET", `/api/join/${JOIN_TOKEN}`, deps);
    expect(res.status).toBe(410);
    expect(await res.text()).not.toContain(JOIN_TOKEN);
    expect(tokens[0]?.used).toBe(false);
    expect(saves).toHaveLength(0);
  });

  it("refuses GET /api/team/invite/<token> with 410 and a body that does not echo the token", async () => {
    const { deps } = makeDeps();
    const res = call("GET", `/api/team/invite/${INVITE_TOKEN}`, deps);
    expect(res.status).toBe(410);
    expect(res.headers.get("content-type")).toContain("application/json");
    const body = await res.text();
    expect(body).toContain("upgrade shipwright");
    expect(body).not.toContain(INVITE_TOKEN);
  });

  it("refuses the retired join form for other methods without redeeming", () => {
    const { deps, tokens } = makeDeps();
    const res = call("POST", `/api/join/${JOIN_TOKEN}`, deps, joinHeader);
    expect(res.status).toBe(410);
    expect(tokens[0]?.used).toBe(false);
  });

  it("ignores a token in the query string (401, the header is missing)", () => {
    const { deps, tokens } = makeDeps();
    const res = handleJoinRoutes(
      new Request(`${BASE}/api/join?token=${JOIN_TOKEN}`, { method: "POST" }),
      "/api/join",
      deps,
    );
    expect(res?.status).toBe(401);
    expect(tokens[0]?.used).toBe(false);
  });
});

describe("POST /api/join (header form)", () => {
  it("serves a script for a valid header token and spends the token", async () => {
    const { deps, tokens, saves } = makeDeps();
    const res = call("POST", "/api/join", deps, joinHeader);
    expect(res.status).toBe(200);
    expect(await res.text()).toMatch(/^#!\/usr\/bin\/env bash/);
    expect(saves).toEqual([1]);
    expect(tokens[0]?.used).toBe(true);
  });

  it("returns a script that never contains the token and passes no --join-token", async () => {
    const { deps } = makeDeps();
    const body = await call("POST", "/api/join", deps, joinHeader).text();
    expect(body).not.toContain(JOIN_TOKEN);
    expect(body).not.toContain("--join-token");
    expect(body).toContain(`DASHBOARD_URL="${BASE}"`);
  });

  it("enforces single use: a second redemption of the same token gets 410", async () => {
    const { deps } = makeDeps();
    expect(call("POST", "/api/join", deps, joinHeader).status).toBe(200);
    const second = call("POST", "/api/join", deps, joinHeader);
    expect(second.status).toBe(410);
    expect(await second.text()).toContain("already-used");
  });

  it("refuses an unknown token with 410", () => {
    const { deps } = makeDeps();
    expect(call("POST", "/api/join", deps, { "X-Shipwright-Join-Token": "nope" }).status).toBe(410);
  });

  it("answers 401 without the header", () => {
    const { deps } = makeDeps();
    expect(call("POST", "/api/join", deps, {}).status).toBe(401);
  });

  it("sends Referrer-Policy no-referrer and no-store on the script", () => {
    const { deps } = makeDeps();
    const res = call("POST", "/api/join", deps, joinHeader);
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");
    expect(res.headers.get("cache-control")).toBe("no-store");
  });
});

describe("POST /api/team/invite/verify (header form)", () => {
  it("verifies a live invite sent in the header", async () => {
    const { deps } = makeDeps();
    const res = call("POST", "/api/team/invite/verify", deps, inviteHeader);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { valid: boolean; dashboard_url: string };
    expect(body.valid).toBe(true);
    expect(body.dashboard_url).toBe(BASE);
  });

  it("refuses an expired invite with 404", async () => {
    const { deps } = makeDeps({ expiredInvite: true });
    const res = call("POST", "/api/team/invite/verify", deps, inviteHeader);
    expect(res.status).toBe(404);
    expect(((await res.json()) as { valid: boolean }).valid).toBe(false);
  });

  it("refuses the token in the query string (400, the header is missing)", () => {
    const { deps } = makeDeps();
    const res = handleJoinRoutes(
      new Request(`${BASE}/api/team/invite/verify?token=${INVITE_TOKEN}`, { method: "POST" }),
      "/api/team/invite/verify",
      deps,
    );
    expect(res?.status).toBe(400);
  });
});

describe("tokens stay out of logs and response headers", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("writes nothing to the console across every join and invite flow", () => {
    const methods = ["log", "info", "warn", "error", "debug"] as const;
    const spies = methods.map((m) => vi.spyOn(console, m).mockImplementation(() => {}));
    const { deps } = makeDeps();
    call("GET", `/api/join/${JOIN_TOKEN}`, deps);
    call("GET", `/api/team/invite/${INVITE_TOKEN}`, deps);
    call("POST", "/api/join", deps, joinHeader);
    call("POST", "/api/join", deps, { "X-Shipwright-Join-Token": "bad-token-xyz" });
    call("POST", "/api/team/invite/verify", deps, inviteHeader);
    call("POST", "/api/team/invite/verify", deps, { "X-Shipwright-Invite-Token": "bad-invite-xyz" });
    for (const spy of spies) expect(spy).not.toHaveBeenCalled();
  });

  it("never returns a join or invite token in a response header", () => {
    const { deps } = makeDeps();
    const responses = [
      call("GET", `/api/join/${JOIN_TOKEN}`, deps),
      call("GET", `/api/team/invite/${INVITE_TOKEN}`, deps),
      call("POST", "/api/join", deps, joinHeader),
      call("POST", "/api/team/invite/verify", deps, inviteHeader),
    ];
    for (const res of responses) {
      res.headers.forEach((value) => {
        expect(value).not.toContain(JOIN_TOKEN);
        expect(value).not.toContain(INVITE_TOKEN);
      });
    }
  });
});

describe("routing", () => {
  it("leaves unrelated paths to the server", () => {
    const { deps } = makeDeps();
    for (const [method, path] of [
      ["GET", "/api/status"],
      ["GET", "/api/join"],
      ["POST", "/api/team/invite"],
    ] as const) {
      const req = new Request(`${BASE}${path}`, { method });
      expect(handleJoinRoutes(req, path, deps)).toBeNull();
    }
  });
});

describe("client commands carry no token", () => {
  it("joinCommand prompts for the token and sends it in a header on stdin", () => {
    const cmd = joinCommand(BASE);
    expect(cmd).toContain("read -rs");
    expect(cmd).toContain("X-Shipwright-Join-Token");
    expect(cmd).toContain("-H @-");
    expect(cmd).toContain(`'${BASE}/api/join'`);
    expect(cmd).not.toMatch(/[?&]token=/);
  });

  it("teamJoinCommand has no token argument", () => {
    expect(teamJoinCommand(BASE)).toBe(`shipwright connect join --url ${BASE}`);
  });

  it("the worker script names no token variable", () => {
    expect(generateJoinScript(BASE, 3)).not.toContain("JOIN_TOKEN");
  });
});
