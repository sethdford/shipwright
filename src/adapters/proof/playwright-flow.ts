import type {
  Capture,
  Flow,
  FlowResult,
  HttpError,
  Step,
  StepOutcome,
} from "../../contexts/quality";

/**
 * Drives one flow in one browser page (ADR-0019). Steps are data from proof.json or from the
 * changed routes; each maps to one fixed Playwright call, so nothing in them is ever evaluated.
 * The minimal Playwright surface used is typed here, so Playwright stays an optional dependency.
 */

export interface PwLocator {
  first(): PwLocator;
  click(o: { timeout: number }): Promise<void>;
  fill(v: string, o: { timeout: number }): Promise<void>;
  press(k: string, o: { timeout: number }): Promise<void>;
  waitFor(o: { timeout: number; state?: "visible" | "attached" }): Promise<void>;
}

export interface PwPage {
  goto(
    url: string,
    o: { timeout: number; waitUntil: "load" },
  ): Promise<{ status(): number } | null>;
  waitForLoadState(s: "networkidle", o: { timeout: number }): Promise<void>;
  locator(selector: string): PwLocator;
  getByText(text: string): PwLocator;
  keyboard: { press(key: string): Promise<void> };
  screenshot(o: { path: string; fullPage: boolean }): Promise<unknown>;
  on(event: string, listener: (arg: never) => void): void;
}

const STEP_TIMEOUT_MS = 15_000;
const GOTO_TIMEOUT_MS = 45_000;
const SETTLE_MS = 5_000;
const MAX_LINES = 20;
const BLOCKED_BY_US = /ERR_BLOCKED_BY_CLIENT/;

export function describeStep(step: Step): string {
  const [kind, value] = Object.entries(step)[0] ?? ["?", ""];
  const shown = typeof value === "object" && value !== null ? JSON.stringify(value) : String(value);
  return `${kind} ${shown}`.slice(0, 200);
}

export interface FlowSink {
  readonly consoleErrors: string[];
  readonly pageErrors: string[];
  readonly httpErrors: HttpError[];
}

/** Records console errors, uncaught exceptions and 5xx responses of one page. */
export function listen(page: PwPage, sink: FlowSink): void {
  const push = <T>(list: T[], v: T) => {
    if (list.length < MAX_LINES) list.push(v);
  };
  page.on("console", ((m: { type(): string; text(): string }) => {
    // Requests the allow list stopped are counted as blocked, not as the app's own errors.
    if (m.type() === "error" && !BLOCKED_BY_US.test(m.text()))
      push(sink.consoleErrors, m.text().slice(0, 500));
  }) as (arg: never) => void);
  page.on("pageerror", ((e: Error) =>
    push(sink.pageErrors, String(e.message ?? e).slice(0, 500))) as (arg: never) => void);
  page.on("response", ((r: { status(): number; url(): string }) => {
    if (r.status() >= 500)
      push(sink.httpErrors, { url: r.url().slice(0, 300), status: r.status() });
  }) as (arg: never) => void);
}

async function settle(page: PwPage): Promise<void> {
  await page.waitForLoadState("networkidle", { timeout: SETTLE_MS }).catch(() => {});
}

async function act(page: PwPage, step: Step, baseUrl: string): Promise<void> {
  const t = { timeout: STEP_TIMEOUT_MS };
  if ("goto" in step) {
    const response = await page.goto(new URL(step.goto, `${baseUrl}/`).href, {
      timeout: GOTO_TIMEOUT_MS,
      waitUntil: "load",
    });
    // A page the change touched that answers 4xx or 5xx is broken, whatever it renders.
    const status = response?.status() ?? 0;
    if (status >= 400) throw new Error(`the page answered HTTP ${status}`);
    return settle(page);
  }
  if ("click" in step) {
    await page.locator(step.click).first().click(t);
    return settle(page);
  }
  if ("fill" in step) return page.locator(step.fill.selector).first().fill(step.fill.value, t);
  if ("press" in step) {
    const { selector, key } = step.press;
    return selector ? page.locator(selector).first().press(key, t) : page.keyboard.press(key);
  }
  if ("waitFor" in step)
    return page
      .locator(step.waitFor)
      .first()
      .waitFor({ ...t, state: "visible" });
  if ("expectText" in step)
    return page
      .getByText(step.expectText)
      .first()
      .waitFor({ ...t, state: "visible" });
}

export interface FlowRun {
  readonly index: number;
  readonly flow: Flow;
  readonly baseUrl: string;
  readonly outDir: string;
}

async function shoot(page: PwPage, run: FlowRun, name: string, shots: Capture[]): Promise<void> {
  const file = `${run.index + 1}-${name}.png`;
  await page.screenshot({ path: `${run.outDir}/${file}`, fullPage: true });
  shots.push({ name, file });
}

/** Runs the steps in order and stops at the first failure, with a screenshot of where it stopped. */
export async function driveFlow(
  page: PwPage,
  run: FlowRun,
): Promise<Omit<FlowResult, "video" | "blocked" | keyof FlowSink>> {
  const steps: StepOutcome[] = [];
  const screenshots: Capture[] = [];
  for (const step of run.flow.steps) {
    const label = describeStep(step);
    try {
      if ("screenshot" in step) await shoot(page, run, step.screenshot, screenshots);
      else await act(page, step, run.baseUrl);
      steps.push({ step: label, ok: true });
    } catch (e) {
      const error =
        (e instanceof Error ? e.message : String(e)).split("\n")[0]?.slice(0, 300) ?? "";
      steps.push({ step: label, ok: false, error });
      await shoot(page, run, "failure", screenshots).catch(() => {});
      break;
    }
  }
  if (screenshots.length === 0) await shoot(page, run, "end", screenshots).catch(() => {});
  return { name: run.flow.name, steps, screenshots };
}
