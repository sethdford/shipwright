import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { BrowseRequest, BrowserDriver, FlowResult } from "../../contexts/quality";
import { driveFlow, type FlowSink, listen, type PwPage } from "./playwright-flow";

/**
 * Headless Chromium through Playwright (ADR-0019). Playwright is optional: when it cannot be
 * loaded or has no browser, unavailable() says so and the proof records that instead of failing.
 * Pages may only reach the app's own origin and the hosts proof.json allows: every other request,
 * WebSocket included, is aborted before it leaves the browser, and service workers are off so
 * none can bypass the routing. Other services on localhost are outside the fence too.
 */

interface PwRoute {
  request(): { url(): string };
  abort(code: string): Promise<void>;
  continue(): Promise<void>;
}

interface PwWebSocketRoute {
  url(): string;
  connectToServer(): unknown;
  close(o?: { code?: number; reason?: string }): Promise<void>;
}

interface PwContext {
  newPage(): Promise<PwPage & { video(): { path(): Promise<string> } | null }>;
  route(pattern: string, handler: (route: PwRoute) => Promise<void>): Promise<void>;
  routeWebSocket?(pattern: RegExp, handler: (ws: PwWebSocketRoute) => unknown): Promise<void>;
  close(): Promise<void>;
}

interface PwBrowser {
  newContext(o: Record<string, unknown>): Promise<PwContext>;
  close(): Promise<void>;
}

interface Playwright {
  chromium: { launch(o: { headless: boolean; executablePath?: string }): Promise<PwBrowser> };
}

export type PlaywrightLoader = () => Promise<Playwright | null>;

const defaultLoader: PlaywrightLoader = async () => {
  try {
    const name = "playwright";
    return (await import(name)) as Playwright;
  } catch {
    return null;
  }
};

const LOCAL = new Set(["localhost", "127.0.0.1", "[::1]"]);
const VIEWPORT = { width: 1280, height: 800 };

/** host:port with the scheme's default port filled in, so origins compare by value. */
function hostPort(u: URL): string {
  const port = u.port || (u.protocol === "https:" || u.protocol === "wss:" ? "443" : "80");
  return `${LOCAL.has(u.hostname) ? "local" : u.hostname}:${port}`;
}

/**
 * True for the app's own host and port (localhost and 127.0.0.1 count as one), inline data, and
 * allowHosts entries (`*.example.com` matches subdomains). Other local ports are refused.
 */
export function hostAllowed(url: string, appUrl: string, allow: readonly string[]): boolean {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  if (u.protocol === "data:" || u.protocol === "blob:" || u.protocol === "about:") return true;
  if (hostPort(u) === hostPort(new URL(appUrl))) return true;
  const host = u.hostname;
  return allow.some((a) => (a.startsWith("*.") ? host.endsWith(a.slice(1)) : host === a));
}

export class PlaywrightBrowser implements BrowserDriver {
  constructor(
    private readonly load: PlaywrightLoader = defaultLoader,
    private readonly executablePath?: string,
  ) {}

  async unavailable(): Promise<string | null> {
    const pw = await this.load();
    if (pw === null)
      return "Playwright is not installed (bun add -d playwright && bunx playwright install chromium)";
    try {
      const browser = await this.launch(pw);
      await browser.close();
      return null;
    } catch (e) {
      const why = e instanceof Error ? (e.message.split("\n")[0] ?? "") : String(e);
      return `Chromium could not start (bunx playwright install chromium): ${why.slice(0, 200)}`;
    }
  }

  async run(request: BrowseRequest): Promise<readonly FlowResult[]> {
    const pw = await this.load();
    if (pw === null) return [];
    const browser = await this.launch(pw);
    try {
      const results: FlowResult[] = [];
      for (const [index, flow] of request.flows.entries())
        results.push(await this.flow(browser, request, index, flow));
      return results;
    } finally {
      await browser.close().catch(() => {});
    }
  }

  private launch(pw: Playwright): Promise<PwBrowser> {
    const path = this.executablePath ? { executablePath: this.executablePath } : {};
    return pw.chromium.launch({ headless: true, ...path });
  }

  private async fence(context: PwContext, req: BrowseRequest, blocked: string[]): Promise<void> {
    const note = (url: string) => {
      if (blocked.length < 20) blocked.push(url.slice(0, 200));
    };
    await context.route("**/*", async (route) => {
      const url = route.request().url();
      if (hostAllowed(url, req.baseUrl, req.allowHosts)) return route.continue();
      note(url);
      return route.abort("blockedbyclient");
    });
    await context.routeWebSocket?.(/.*/, (ws) => {
      if (hostAllowed(ws.url(), req.baseUrl, req.allowHosts)) return ws.connectToServer();
      note(ws.url());
      return ws.close({ code: 1008, reason: "blocked by shipwright proof" });
    });
  }

  private async flow(
    browser: PwBrowser,
    req: BrowseRequest,
    index: number,
    flow: BrowseRequest["flows"][number],
  ): Promise<FlowResult> {
    // A private folder for the raw recording; its bytes are handed to save() and it is removed.
    const videoDir = req.video ? mkdtempSync(join(tmpdir(), "sw-proof-video-")) : null;
    try {
      const recordVideo = videoDir ? { recordVideo: { dir: videoDir, size: VIEWPORT } } : {};
      const options = { viewport: VIEWPORT, serviceWorkers: "block", ...recordVideo };
      const context = await browser.newContext(options);
      const blocked: string[] = [];
      await this.fence(context, req, blocked);
      const page = await context.newPage();
      const sink: FlowSink = { consoleErrors: [], pageErrors: [], httpErrors: [] };
      listen(page, sink);
      const driven = await driveFlow(page, { index, flow, baseUrl: req.baseUrl, save: req.save });
      const recording = page.video();
      await context.close().catch(() => {});
      const video = recording ? await keepVideo(recording, req, index) : null;
      return { ...driven, ...sink, blocked, video };
    } finally {
      if (videoDir) rmSync(videoDir, { recursive: true, force: true });
    }
  }
}

async function keepVideo(
  recording: { path(): Promise<string> },
  req: BrowseRequest,
  index: number,
): Promise<string | null> {
  try {
    const file = `${index + 1}-flow.webm`;
    await req.save(file, readFileSync(await recording.path()));
    return file;
  } catch {
    return null;
  }
}
