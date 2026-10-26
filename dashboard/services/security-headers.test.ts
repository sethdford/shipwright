// @vitest-environment node
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import { createServer, type AddressInfo } from "node:net";
import { DASHBOARD_CSP, INLINE_PAGE_CSP, htmlSecurityHeaders, inlinePageHeaders } from "./security-headers";

function directives(csp: string): Map<string, string> {
  return new Map(
    csp.split(";").map((d) => {
      const [name, ...values] = d.trim().split(/\s+/);
      return [name, values.join(" ")] as const;
    }),
  );
}

describe("dashboard CSP", () => {
  const d = directives(DASHBOARD_CSP);

  it("is same-origin by default and blocks framing, base and foreign form targets", () => {
    expect(d.get("default-src")).toBe("'self'");
    expect(d.get("frame-ancestors")).toBe("'none'");
    expect(d.get("base-uri")).toBe("'none'");
    expect(d.get("form-action")).toBe("'self'");
  });

  it("allows no inline or remote script", () => {
    expect(d.get("script-src")).toBe("'self'");
    expect(DASHBOARD_CSP).not.toMatch(/unsafe-eval|https?:|\*/);
  });

  it("keeps <style> elements same-origin; only style attributes may be inline", () => {
    expect(d.get("style-src")).toBe("'self'");
    expect(d.get("style-src-attr")).toBe("'unsafe-inline'");
    expect(d.has("style-src-elem")).toBe(false);
  });

  it("loads images only from self and data: (no remote avatars)", () => {
    expect(d.get("img-src")).toBe("'self' data:");
    expect(d.get("connect-src")).toBe("'self'");
    expect(d.get("font-src")).toBe("'self'");
  });

  it("is sent as a Content-Security-Policy header", () => {
    expect(htmlSecurityHeaders()).toEqual({ "Content-Security-Policy": DASHBOARD_CSP });
  });

  it("blocks plugins and is mirrored by a strict policy for server-rendered pages", () => {
    expect(d.get("object-src")).toBe("'none'");
    const inline = directives(INLINE_PAGE_CSP);
    expect(inline.get("default-src")).toBe("'none'");
    expect(inline.get("frame-ancestors")).toBe("'none'");
    expect(inline.get("object-src")).toBe("'none'");
    expect(inline.has("script-src")).toBe(false);
    expect(inlinePageHeaders()["Content-Security-Policy"]).toBe(INLINE_PAGE_CSP);
  });
});

describe("index.html is CSP-clean", () => {
  const html = readFileSync(join(__dirname, "..", "public", "index.html"), "utf8");

  it("has no inline script, inline handler or inline style", () => {
    expect(html).not.toMatch(/<script(?![^>]*\bsrc=)[^>]*>/);
    expect(html).not.toMatch(/\son[a-z]+=/i);
    expect(html).not.toMatch(/\sstyle=/);
    expect(html).not.toMatch(/<style[\s>]/);
  });

  it("uses the T1 favicon and no remote resource", () => {
    expect(html).toContain('href="favicon.svg"');
    expect(html).not.toMatch(/(src|href)="(https?:)?\/\//);
  });
});

// Real server processes against throwaway HOMEs: the header must be on the wire.
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.once("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const port = (srv.address() as AddressInfo).port;
      srv.close(() => resolve(port));
    });
  });
}

interface Running {
  base: string;
  stop(): Promise<void>;
}

async function startServer(extraEnv: Record<string, string> = {}): Promise<Running> {
  const port = await freePort();
  const home = mkdtempSync(join(tmpdir(), "sw-csp-"));
  const child: ChildProcess = spawn("bun", [join(__dirname, "..", "server.ts")], {
    env: { PATH: process.env.PATH, HOME: home, SHIPWRIGHT_DASHBOARD_PORT: String(port), ...extraEnv },
    stdio: "ignore",
  });
  const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
  const stop = async () => {
    child.kill("SIGTERM");
    await exited;
    rmSync(home, { recursive: true, force: true });
  };
  const base = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 100; i++) {
    try {
      if ((await fetch(base + "/api/health")).ok) return { base, stop };
    } catch {
      // not listening yet
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  await stop();
  throw new Error("dashboard server did not start");
}

const INLINE_HANDLER = /\son[a-z]+\s*=/i;

describe("dashboard server sends the CSP (auth off)", () => {
  let srv: Running;
  beforeAll(async () => {
    srv = await startServer();
  }, 20000);
  afterAll(() => srv?.stop(), 10000);

  it("on the dashboard page", async () => {
    const res = await fetch(srv.base + "/");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-security-policy")).toBe(DASHBOARD_CSP);
  });

  it("on the logout confirmation page, which has no script or inline handler", async () => {
    const res = await fetch(srv.base + "/auth/logout");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-security-policy")).toBe(INLINE_PAGE_CSP);
    const html = await res.text();
    expect(html).not.toMatch(/<script|https?:\/\/fonts\./);
    expect(html).not.toMatch(INLINE_HANDLER);
  });

  it("not on static assets", async () => {
    const res = await fetch(srv.base + "/styles.css");
    expect(res.headers.get("content-security-policy")).toBeNull();
  });
});

describe("dashboard server sends the CSP (PAT sign-in)", () => {
  let srv: Running;
  beforeAll(async () => {
    srv = await startServer({ GITHUB_PAT: "test-not-a-token", DASHBOARD_REPO: "example/repo" });
  }, 20000);
  afterAll(() => srv?.stop(), 10000);

  it("on the login page, which the policy does not break", async () => {
    const res = await fetch(srv.base + "/login");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-security-policy")).toBe(INLINE_PAGE_CSP);
    const html = await res.text();
    expect(html).toContain('action="/auth/pat-login"');
    expect(html).not.toMatch(/<script|https?:\/\/fonts\./);
    expect(html).not.toMatch(INLINE_HANDLER);
  });
});
