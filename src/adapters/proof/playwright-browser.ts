import { mkdirSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import type { BrowseRequest, BrowserDriver, FlowResult } from "../../contexts/quality";
import { driveFlow, type FlowSink, listen, type PwPage } from "./playwright-flow";

/**
 * Headless Chromium through Playwright (ADR-0019). Playwright is optional: when it cannot be
 * loaded or has no browser, unavailable() says so and the proof records that instead of failing.
 * Pages may only reach the app itself and the hosts proof.json allows; every other request is
 * aborted before it leaves the machine, so a page cannot send data out or pull in remote code.
 */

interface PwRoute {
  request(): { url(): string };
  abort(code: string): Promise<void>;
  continue(): Promise<void>;
}

interface PwContext {
  newPage(): Promise<PwPage & { video(): { path(): Promise<string> } | null }>;
  route(pattern: string, handler: (route: PwRoute) => Promise<void>): Promise<void>;
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

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]", "::1"]);

/** True for the app's own host, local hosts, and allowHosts entries (`*.example.com` matches subdomains). */
export function hostAllowed(url: string, appHost: string, allow: readonly string[]): boolean {
  let host: string;
  try {
    const u = new URL(url);
    if (u.protocol === "data:" || u.protocol === "blob:" || u.protocol === "about:") return true;
    host = u.hostname;
  } catch {
    return false;
  }
  if (host === appHost || LOCAL_HOSTS.has(host)) return true;
  return allow.some((a) => (a.startsWith("*.") ? host.endsWith(a.slice(1)) : host === a));
}

export class PlaywrightBrowser implements BrowserDriver {
  private launchError: string | null = null;

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
      this.launchError = e instanceof Error ? (e.message.split("\n")[0] ?? "") : String(e);
      return `Chromium could not start (bunx playwright install chromium): ${this.launchError.slice(0, 200)}`;
    }
  }

  async run(request: BrowseRequest): Promise<readonly FlowResult[]> {
    const pw = await this.load();
    if (pw === null) return [];
    mkdirSync(request.outDir, { recursive: true });
    const browser = await this.launch(pw);
    try {
      const results: FlowResult[] = [];
      for (const [index, flow] of request.flows.entries())
        results.push(await this.flow(browser, request, index, flow));
      return results;
    } finally {
      await browser.close().catch(() => {});
      rmSync(join(request.outDir, ".video"), { recursive: true, force: true });
    }
  }

  private launch(pw: Playwright): Promise<PwBrowser> {
    return pw.chromium.launch({
      headless: true,
      ...(this.executablePath ? { executablePath: this.executablePath } : {}),
    });
  }

  private async flow(
    browser: PwBrowser,
    req: BrowseRequest,
    index: number,
    flow: BrowseRequest["flows"][number],
  ): Promise<FlowResult> {
    const videoDir = join(req.outDir, ".video");
    const context = await browser.newContext({
      viewport: { width: 1280, height: 800 },
      ...(req.video ? { recordVideo: { dir: videoDir, size: { width: 1280, height: 800 } } } : {}),
    });
    const blocked: string[] = [];
    const appHost = new URL(req.baseUrl).hostname;
    await context.route("**/*", async (route) => {
      const url = route.request().url();
      if (hostAllowed(url, appHost, req.allowHosts)) return route.continue();
      if (blocked.length < 20) blocked.push(url.slice(0, 200));
      return route.abort("blockedbyclient");
    });
    const page = await context.newPage();
    const sink: FlowSink = { consoleErrors: [], pageErrors: [], httpErrors: [] };
    listen(page, sink);
    const driven = await driveFlow(page, { index, flow, baseUrl: req.baseUrl, outDir: req.outDir });
    const recording = page.video();
    await context.close().catch(() => {});
    const video = recording ? await this.keepVideo(recording, req.outDir, index) : null;
    return { ...driven, ...sink, blocked, video };
  }

  private async keepVideo(
    recording: { path(): Promise<string> },
    outDir: string,
    index: number,
  ): Promise<string | null> {
    try {
      const file = `${index + 1}-flow.webm`;
      renameSync(await recording.path(), join(outDir, file));
      return file;
    } catch {
      return null;
    }
  }
}
