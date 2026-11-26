import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { hostAllowed, PlaywrightBrowser } from "./playwright-browser";

let env: TestEnv;
beforeEach(() => {
  env = createTestEnv();
});
afterEach(() => env.cleanup());

test("pages reach only the app, local hosts and the allow list", () => {
  expect(hostAllowed("http://127.0.0.1:3000/a.js", "127.0.0.1", [])).toBe(true);
  expect(hostAllowed("http://localhost:3000/", "127.0.0.1", [])).toBe(true);
  expect(hostAllowed("data:image/png;base64,xx", "127.0.0.1", [])).toBe(true);
  expect(hostAllowed("https://fonts.googleapis.com/css", "127.0.0.1", [])).toBe(false);
  expect(
    hostAllowed("https://fonts.googleapis.com/css", "127.0.0.1", ["fonts.googleapis.com"]),
  ).toBe(true);
  expect(hostAllowed("https://a.cdn.example.com/x", "127.0.0.1", ["*.example.com"])).toBe(true);
  expect(hostAllowed("https://example.com.evil.io/x", "127.0.0.1", ["*.example.com"])).toBe(false);
  expect(hostAllowed("not a url", "127.0.0.1", [])).toBe(false);
});

test("without Playwright the driver says how to install it", async () => {
  const b = new PlaywrightBrowser(async () => null);
  expect(await b.unavailable()).toContain("playwright install chromium");
  expect(
    await b.run({ baseUrl: "http://x", flows: [], outDir: env.root, allowHosts: [], video: false }),
  ).toEqual([]);
});

// End to end with a real Chromium where one is installed (CI without Playwright skips this).
const hasPlaywright = await (async () => {
  try {
    const b = new PlaywrightBrowser();
    return (await b.unavailable()) === null;
  } catch {
    return false;
  }
})();

test.skipIf(!hasPlaywright)(
  "drives a flow: fill, click, expect, screenshot; blocks outside hosts",
  async () => {
    const server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(req) {
        const url = new URL(req.url);
        const html = (b: string) =>
          new Response(
            `<html><body>${b}<img src="https://tracker.example.com/p.gif"></body></html>`,
            { headers: { "content-type": "text/html" } },
          );
        if (url.pathname === "/")
          return html(
            `<form action="/add"><input id="item" name="item"><button>Add</button></form>`,
          );
        if (url.pathname === "/add") return html(`<h1>Added: ${url.searchParams.get("item")}</h1>`);
        if (url.pathname === "/boom") return new Response("err", { status: 500 });
        return new Response("missing", { status: 404 });
      },
    });
    try {
      const b = new PlaywrightBrowser();
      const results = await b.run({
        baseUrl: `http://127.0.0.1:${server.port}`,
        outDir: env.root,
        allowHosts: [],
        video: true,
        flows: [
          {
            name: "add",
            steps: [
              { goto: "/" },
              { fill: { selector: "#item", value: "milk" } },
              { click: "button" },
              { expectText: "Added: milk" },
              { screenshot: "added" },
            ],
          },
          { name: "broken", steps: [{ goto: "/boom" }] },
        ],
      });
      const [add, broken] = results;
      expect(add?.steps.every((s) => s.ok)).toBe(true);
      expect(add?.screenshots).toEqual([{ name: "added", file: "1-added.png" }]);
      expect(existsSync(join(env.root, "1-added.png"))).toBe(true);
      expect(add?.video).toBe("1-flow.webm");
      expect(existsSync(join(env.root, ".video"))).toBe(false);
      expect(add?.blocked[0]).toContain("tracker.example.com");
      expect(add?.consoleErrors).toEqual([]);
      expect(broken?.steps[0]?.ok).toBe(false);
      expect(broken?.steps[0]?.error).toContain("HTTP 500");
      expect(broken?.screenshots.map((s) => s.name)).toEqual(["failure"]);
    } finally {
      server.stop(true);
    }
  },
  120_000,
);
