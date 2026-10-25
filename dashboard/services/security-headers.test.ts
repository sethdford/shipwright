import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { DASHBOARD_CSP, htmlSecurityHeaders } from "./security-headers";

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

  it("is applied to HTML served from public/ by server.ts", () => {
    const server = readFileSync(join(__dirname, "..", "server.ts"), "utf8");
    const fn = server.slice(server.indexOf("function serveStaticFile"), server.indexOf("// ─── File watcher"));
    expect(fn).toContain('ext === ".html" ? htmlSecurityHeaders() : {}');
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
