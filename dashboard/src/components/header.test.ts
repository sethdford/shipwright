import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

function brakeOk() {
  return {
    paused: 2,
    running: 2,
    queued: 0,
    jobs: [
      { issue: 1, pid: 101, signalled: [103, 102, 101], failed: [] },
      { issue: 2, pid: 201, signalled: [202, 201], failed: [] },
    ],
  };
}

vi.mock("../core/api", () => ({
  fetchMe: vi.fn(() => Promise.resolve({ username: "Ada Lovelace", role: "operator" })),
  fetchDaemonConfig: vi.fn(() => Promise.resolve({})),
  fetchAlerts: vi.fn(() => Promise.resolve({ alerts: [] })),
  emergencyBrake: vi.fn(() => Promise.resolve(brakeOk())),
  pauseIntakeForBrake: vi.fn(() => Promise.resolve({ ok: true })),
  sendIntervention: vi.fn(() => Promise.resolve({ ok: true })),
  daemonControl: vi.fn(() => Promise.resolve({ ok: true })),
}));

import {
  daemonStopBody,
  bannerText,
  connectionShort,
  connectionState,
  connectionText,
  initialsFor,
  setupHeader,
  STALE_MS,
} from "./header";
import { engageBrake } from "./brake";
import { pausedRuns, sendRunAction } from "./modal";
import { store } from "../core/state";
import * as api from "../core/api";

const T = new Date(2026, 9, 25, 14, 2, 0).getTime();
const at1401 = new Date(2026, 9, 25, 14, 1).getTime();

describe("connectionState", () => {
  it("is connecting until the first data arrives, even once the socket is open", () => {
    expect(connectionState({ connected: false, disconnectedAt: null, lastDataAt: null, now: T })).toBe("connecting");
    expect(connectionState({ connected: true, disconnectedAt: null, lastDataAt: null, now: T })).toBe("connecting");
  });

  it("is live with fresh data and stale when data stops while connected", () => {
    expect(connectionState({ connected: true, disconnectedAt: null, lastDataAt: T - 2000, now: T })).toBe("live");
    expect(connectionState({ connected: true, disconnectedAt: null, lastDataAt: T - STALE_MS - 1, now: T })).toBe("stale");
  });

  it("is reconnecting just after a drop, then offline", () => {
    const base = { connected: false, lastDataAt: T - 5000 };
    expect(connectionState({ ...base, disconnectedAt: T - 1000, now: T })).toBe("reconnecting");
    expect(connectionState({ ...base, disconnectedAt: T - STALE_MS - 1, now: T })).toBe("offline");
  });
});

describe("connection labels share one vocabulary", () => {
  const live = { connected: true, disconnectedAt: null, lastDataAt: T - 2000, now: T };
  const off = { connected: false, disconnectedAt: T - 60000, lastDataAt: at1401, now: T };

  it("header text", () => {
    expect(connectionText("live", live)).toBe("Live · just now");
    expect(connectionText("live", { ...live, lastDataAt: T - 12000 })).toBe("Live · updated 12s ago");
    expect(connectionText("stale", { ...live, lastDataAt: at1401 })).toBe("Stale · data from 14:01");
    expect(connectionText("offline", off)).toBe("Offline since 14:01");
    expect(connectionText("reconnecting", off)).toBe("Reconnecting");
  });

  it("short labels use the same words", () => {
    expect(["live", "stale", "reconnecting", "offline", "connecting"].map((s) => connectionShort(s as never))).toEqual([
      "Live",
      "Stale",
      "Reconnecting",
      "Offline",
      "Connecting",
    ]);
  });

  it("banner text names the state, the data time and the brake", () => {
    expect(bannerText("offline", off)).toBe(
      "Offline since 14:01 · data from 14:01. Actions are off; the emergency brake still works.",
    );
    expect(bannerText("reconnecting", { ...off, lastDataAt: null })).toBe(
      "Reconnecting · no data yet. Actions are off; the emergency brake still works.",
    );
  });
});

describe("initialsFor", () => {
  it.each([
    ["Ada Lovelace", "AL"],
    ["sethford", "SE"],
    ["grace.hopper", "GH"],
    ["  ", "?"],
  ])("%s -> %s", (name, want) => {
    expect(initialsFor(name)).toBe(want);
  });
});

describe("emergency brake", () => {
  function mount(html: string): void {
    const doc = new DOMParser().parseFromString(html, "text/html");
    document.body.replaceChildren(...Array.from(doc.body.childNodes));
  }

  beforeEach(() => {
    vi.useFakeTimers();
    localStorage.clear();
    pausedRuns.clear();
    mount(`
      <span id="conn"><span id="conn-text"></span></span><span id="conn-live"></span>
      <button id="emergency-brake"><span class="label-long">Emergency brake</span><span class="label-short">Pause all</span></button>
      <div id="brake-state" role="status" hidden></div>
      <div id="brake-alert" role="alert" hidden></div>
      <dialog id="emergency-modal">
        <p id="brake-desc"></p>
        <button data-close autofocus>Cancel</button>
        <button id="emergency-confirm" data-close>Engage brake</button>
      </dialog>
      <div id="toast" hidden></div>`);
    store.set("connected", false);
    store.set("currentUser", null);
    // Keep /api/me pending so each test controls the role.
    vi.mocked(api.fetchMe).mockReturnValue(new Promise(() => {}));
    setupHeader();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.clearAllMocks();
  });

  const dialog = () => document.getElementById("emergency-modal") as HTMLDialogElement;
  const brake = () => document.getElementById("emergency-brake") as HTMLButtonElement;
  const toastText = () => document.getElementById("toast")?.textContent ?? "";
  const alertEl = () => document.getElementById("brake-alert") as HTMLElement;
  const stateEl = () => document.getElementById("brake-state") as HTMLElement;
  const items = () => Array.from(alertEl().querySelectorAll("li")).map((li) => li.textContent);
  const button = (root: ParentNode, text: string) =>
    Array.from(root.querySelectorAll("button")).find((b) => b.textContent === text) as HTMLButtonElement;
  const ready = () => {
    store.set("connected", true);
    store.set("currentUser", { username: "ada", role: "operator" });
    store.set("fleetState", { pipelines: [{ issue: 1 }, { issue: 2 }] } as never);
  };
  const flush = async () => {
    for (let i = 0; i < 6; i++) await Promise.resolve();
  };

  const operator = () => store.set("currentUser", { username: "ada", role: "operator" });

  it("works while disconnected: the brake is exempt from the connection gate", async () => {
    operator();
    expect(brake().hasAttribute("aria-disabled")).toBe(false);
    brake().click();
    expect(dialog().open).toBe(true);
    expect(document.getElementById("brake-desc")?.textContent).toMatch(/how many runs are running is unknown here/);
    await engageBrake();
    expect(api.pauseIntakeForBrake).toHaveBeenCalledTimes(1);
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
    expect(toastText()).toBe("Emergency brake engaged: intake paused; all 2 running runs paused (5 processes).");
  });

  it("stays engaged in the shell: pressed button, a status line, and a click opens Release", async () => {
    ready();
    await engageBrake();
    expect(brake().getAttribute("aria-pressed")).toBe("true");
    expect(brake().querySelector(".label-long")?.textContent).toBe("Brake engaged");
    expect(stateEl().hidden).toBe(false);
    expect(stateEl().textContent).toMatch(/^Brake engaged since \d\d:\d\d · intake paused · 2 runs paused by it/);
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}").issues).toEqual([1, 2]);
    brake().click();
    await flush();
    const release = document.querySelector("dialog.confirm-dialog") as HTMLDialogElement;
    expect(release.querySelector("h2")?.textContent).toBe("Release the emergency brake?");
    expect(release.querySelector("p")?.textContent).toBe(
      "This resumes daemon intake and the 2 runs this brake paused (#1, #2). Runs paused another way stay paused.",
    );
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
  });

  it("releases intake and exactly the runs it paused, behind the confirmation", async () => {
    ready();
    vi.mocked(api.sendIntervention).mockResolvedValue({ ok: true, signalled: [1], failed: [] } as never);
    await engageBrake();
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(api.daemonControl).toHaveBeenCalledWith("resume");
    expect(vi.mocked(api.sendIntervention).mock.calls).toEqual([
      [1, "resume"],
      [2, "resume"],
    ]);
    expect(toastText()).toBe("Emergency brake released: intake resumed; 2 runs resumed.");
    expect(brake().getAttribute("aria-pressed")).toBe("false");
    expect(stateEl().hidden).toBe(true);
    expect(localStorage.getItem("sw-brake")).toBeNull();
  });

  it("keeps what a release could not resume, and says so until dismissed", async () => {
    ready();
    vi.mocked(api.sendIntervention)
      .mockResolvedValueOnce({ ok: true, signalled: [1], failed: [] } as never)
      .mockResolvedValueOnce({ ok: false, signalled: [201], failed: [{ pid: 202, error: "EPERM" }] } as never);
    await engageBrake();
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(alertEl().querySelector("h2")?.textContent).toBe("Brake release incomplete");
    expect(items()).toEqual(["#2: not resumed."]);
    expect(stateEl().textContent).toMatch(/· intake resumed · 1 run paused by it/);
    expect(brake().getAttribute("aria-pressed")).toBe("true");
  });

  it("counts a run that ended while braked as released, not as a failure", async () => {
    ready();
    vi.mocked(api.sendIntervention)
      .mockResolvedValueOnce({ ok: true, signalled: [1], failed: [] } as never)
      .mockResolvedValueOnce({ ok: false, signalled: [], failed: [], refused: "not running" } as never);
    await engageBrake();
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(toastText()).toBe("Emergency brake released: intake resumed; 1 run resumed; #2 had already ended.");
    expect(alertEl().hidden).toBe(true);
    expect(brake().getAttribute("aria-pressed")).toBe("false");
  });

  it("fails closed until the role has loaded, and a disabled click explains why", () => {
    expect(brake().getAttribute("aria-disabled")).toBe("true");
    expect(brake().title).toMatch(/role is still loading/);
    brake().click();
    expect(dialog().open).toBe(false);
    expect(toastText()).toMatch(/role is still loading/);
    expect(document.getElementById("toast")?.getAttribute("role")).toBe("alert");
  });

  it("stays off, and says why, when /api/me fails", async () => {
    vi.mocked(api.fetchMe).mockRejectedValueOnce(new Error("HTTP 500"));
    setupHeader();
    await Promise.resolve();
    await Promise.resolve();
    expect(brake().getAttribute("aria-disabled")).toBe("true");
    expect(brake().title).toBe("Your role could not be loaded, so actions are off.");
  });

  it.each([["viewer"], ["guest"], [undefined], ["superuser"]])("is refused for role %s", (role) => {
    store.set("currentUser", { username: "x", role } as never);
    expect(brake().getAttribute("aria-disabled")).toBe("true");
    brake().click();
    expect(dialog().open).toBe(false);
  });

  it("states the live count in the dialog when the feed is live, with Cancel focused", () => {
    ready();
    brake().click();
    expect(document.activeElement?.textContent).toBe("Cancel");
    expect(document.getElementById("brake-desc")?.textContent).toMatch(/each running run \(2 now\)/);
    expect(api.emergencyBrake).not.toHaveBeenCalled();
  });

  it("is incomplete, naming each run in plain words, in an alert that stays until dismissed", async () => {
    ready();
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      paused: 0,
      running: 2,
      queued: 0,
      jobs: [
        { issue: 1, pid: 101, signalled: [], failed: [], refused: "no pipeline for #1 under this process" },
        { issue: 2, pid: 201, signalled: [201], failed: [{ pid: 202, error: "EPERM" }] },
      ],
    } as never);
    await engageBrake();
    expect(alertEl().hidden).toBe(false);
    expect(alertEl().getAttribute("role")).toBe("alert");
    expect(alertEl().querySelector("h2")?.textContent).toBe("Emergency brake incomplete");
    expect(items()).toEqual([
      "#1: could not be confirmed as this run's pipeline, so nothing was paused.",
      "#2: 1 process could not be paused.",
    ]);
    // Raw reasons only behind the disclosure.
    expect(alertEl().querySelector("details pre")?.textContent).toBe(
      "#1 pid 101: no pipeline for #1 under this process\n#2 pid 201: 202 EPERM",
    );
    vi.advanceTimersByTime(60_000);
    expect(alertEl().hidden).toBe(false);
    button(alertEl(), "Dismiss").click();
    expect(alertEl().hidden).toBe(true);
  });

  it("says when the server did not answer, keeps that visible, and a retry confirms it", async () => {
    ready();
    vi.mocked(api.pauseIntakeForBrake).mockRejectedValueOnce(new TypeError("Failed to fetch"));
    vi.mocked(api.emergencyBrake).mockRejectedValueOnce(new TypeError("Failed to fetch"));
    await engageBrake();
    expect(items()).toEqual([
      "Intake: not confirmed paused. The dashboard server did not answer the brake; it may have acted.",
      "Runs: not confirmed paused. The dashboard server did not answer the brake; it may have acted.",
    ]);
    expect(alertEl().textContent).toMatch(/Next: Retry the brake\./);
    // Nothing was confirmed, but the server may have acted: the brake stays visible, retry only.
    expect(brake().getAttribute("aria-pressed")).toBe("mixed");
    expect(stateEl().textContent).toMatch(/^Brake unconfirmed since .* · intake may be paused · runs may be paused · its last attempt got no answer: retry to confirm/);
    expect(button(stateEl(), "Release brake…")).toBeUndefined();
    button(alertEl(), "Dismiss").click();
    expect(stateEl().hidden).toBe(false);
    // Kept across reloads.
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}")).toMatchObject({ uncertain: true, intakeUncertain: true });
    button(stateEl(), "Retry brake…").click();
    expect(dialog().open).toBe(true);
    (document.getElementById("emergency-confirm") as HTMLButtonElement).click();
    await flush();
    expect(api.emergencyBrake).toHaveBeenCalledTimes(2);
    expect(alertEl().hidden).toBe(true);
    expect(brake().getAttribute("aria-pressed")).toBe("true");
  });

  it("never reports success when the intake pause fails, and still sends both", async () => {
    ready();
    vi.mocked(api.pauseIntakeForBrake).mockRejectedValueOnce(Object.assign(new Error("HTTP 500"), { status: 500 }));
    await engageBrake();
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
    expect(items()).toEqual(["Intake: not confirmed paused. The dashboard server refused the brake (HTTP 500)."]);
    expect(stateEl().textContent).toMatch(/^Brake partly engaged since .* · intake not confirmed paused · 2 runs paused by it/);
    // Partly engaged: the brake retries rather than releasing.
    expect(brake().getAttribute("aria-pressed")).toBe("mixed");
    brake().click();
    expect(dialog().open).toBe(true);
    expect(button(stateEl(), "Retry brake…")).toBeTruthy();
  });

  it("leaves what was already paused out of the release: runs and intake", async () => {
    ready();
    vi.mocked(api.pauseIntakeForBrake).mockResolvedValueOnce({ ok: true, wasPaused: true });
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: [
        { issue: 1, pid: 101, signalled: [103, 102, 101], failed: [], wasPaused: true },
        { issue: 2, pid: 201, signalled: [202, 201], failed: [], wasPaused: false },
      ],
    } as never);
    vi.mocked(api.sendIntervention).mockResolvedValue({ ok: true, signalled: [201], failed: [] } as never);
    await engageBrake();
    expect(toastText()).toBe(
      "Emergency brake engaged: intake was already paused; 1 of 2 running runs paused (2 processes). #1 was already paused and stays paused on release.",
    );
    expect(stateEl().textContent).toMatch(/intake was already paused · 1 run paused by it/);
    brake().click();
    await flush();
    const release = document.querySelector("dialog.confirm-dialog") as HTMLElement;
    expect(release.querySelector("p")?.textContent).toBe(
      "This resumes the 1 run this brake paused (#2). Runs paused another way stay paused. Intake was paused before the brake and stays paused.",
    );
    button(release, "Release brake").click();
    await flush();
    expect(api.daemonControl).not.toHaveBeenCalled();
    expect(vi.mocked(api.sendIntervention).mock.calls).toEqual([[2, "resume"]]);
  });

  it("on a retry, still counts what the first attempt paused as the brake's own", async () => {
    ready();
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: [
        { issue: 1, pid: 101, signalled: [101], failed: [], wasPaused: false },
        { issue: 2, pid: 201, signalled: [], failed: [], refused: "not running" },
      ],
    } as never);
    await engageBrake();
    expect(brake().getAttribute("aria-pressed")).toBe("mixed");
    vi.mocked(api.pauseIntakeForBrake).mockResolvedValueOnce({ ok: true, wasPaused: true });
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: [
        { issue: 1, pid: 101, signalled: [101], failed: [], wasPaused: true },
        { issue: 2, pid: 201, signalled: [201], failed: [], wasPaused: false },
      ],
    } as never);
    await engageBrake();
    expect(toastText()).toBe("Emergency brake engaged: intake paused; all 2 running runs paused (2 processes).");
    expect(brake().getAttribute("aria-pressed")).toBe("true");
    brake().click();
    await flush();
    expect(document.querySelector("dialog.confirm-dialog p")?.textContent).toBe(
      "This resumes daemon intake and the 2 runs this brake paused (#1, #2). Runs paused another way stay paused.",
    );
  });

  it("keeps a partly paused run as its own: a retry that finds it paused still releases it", async () => {
    ready();
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: [
        { issue: 1, pid: 101, signalled: [101], failed: [], wasPaused: false },
        { issue: 2, pid: 201, signalled: [201], failed: [{ pid: 202, error: "still running" }], wasPaused: false },
      ],
    } as never);
    await engageBrake();
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: brakeOk().jobs.map((j) => ({ ...j, wasPaused: true })),
    } as never);
    await engageBrake();
    expect(toastText()).toBe("Emergency brake engaged: intake paused; all 2 running runs paused (5 processes).");
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}").issues).toEqual([1, 2]);
  });

  it("after an unanswered brake, a retry that finds everything paused counts it as its own", async () => {
    ready();
    vi.mocked(api.pauseIntakeForBrake).mockRejectedValueOnce(new TypeError("Failed to fetch"));
    vi.mocked(api.emergencyBrake).mockRejectedValueOnce(new TypeError("Failed to fetch"));
    await engageBrake();
    expect(brake().getAttribute("aria-pressed")).toBe("mixed");
    // The server did act; only the answers were lost.
    vi.mocked(api.pauseIntakeForBrake).mockResolvedValueOnce({ ok: true, wasPaused: true });
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: brakeOk().jobs.map((j) => ({ ...j, wasPaused: true })),
    } as never);
    await engageBrake();
    expect(toastText()).toBe("Emergency brake engaged: intake paused; all 2 running runs paused (5 processes).");
    expect(brake().getAttribute("aria-pressed")).toBe("true");
    brake().click();
    await flush();
    expect(document.querySelector("dialog.confirm-dialog p")?.textContent).toBe(
      "This resumes daemon intake and the 2 runs this brake paused (#1, #2). Runs paused another way stay paused.",
    );
  });

  it("still says intake was already paused after a partial release", async () => {
    ready();
    vi.mocked(api.pauseIntakeForBrake).mockResolvedValueOnce({ ok: true, wasPaused: true });
    vi.mocked(api.sendIntervention)
      .mockResolvedValueOnce({ ok: true, signalled: [101], failed: [] } as never)
      .mockResolvedValueOnce({ ok: false, signalled: [201], failed: [{ pid: 202, error: "EPERM" }] } as never);
    await engageBrake();
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(stateEl().textContent).toMatch(/· intake was already paused · 1 run paused by it/);
  });

  it("offers no release while the last attempt is unanswered: what it paused is unknown", async () => {
    ready();
    vi.mocked(api.emergencyBrake).mockRejectedValueOnce(new TypeError("Failed to fetch"));
    await engageBrake();
    // Intake was confirmed, so the brake holds something, but the runs are unknown.
    expect(brake().getAttribute("aria-pressed")).toBe("mixed");
    expect(stateEl().textContent).toMatch(/intake paused · runs may be paused · its last attempt got no answer: retry to confirm/);
    expect(button(stateEl(), "Release brake…")).toBeUndefined();
    expect(button(stateEl(), "Retry brake…")).toBeTruthy();
  });

  it("stays unconfirmed when a retry after a lost answer is refused: a refusal confirms nothing", async () => {
    ready();
    vi.mocked(api.pauseIntakeForBrake).mockRejectedValueOnce(new TypeError("Failed to fetch"));
    vi.mocked(api.emergencyBrake).mockRejectedValueOnce(new TypeError("Failed to fetch"));
    await engageBrake();
    const refused = () => Object.assign(new Error("HTTP 500"), { status: 500 });
    vi.mocked(api.pauseIntakeForBrake).mockRejectedValueOnce(refused());
    vi.mocked(api.emergencyBrake).mockRejectedValueOnce(refused());
    await engageBrake();
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}")).toMatchObject({ uncertain: true, intakeUncertain: true });
    expect(stateEl().textContent).toMatch(/its last attempt got no answer: retry to confirm/);
    expect(button(stateEl(), "Release brake…")).toBeUndefined();
    // A retry that is answered then counts what the lost attempt paused as the brake's own.
    vi.mocked(api.pauseIntakeForBrake).mockResolvedValueOnce({ ok: true, wasPaused: true });
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: brakeOk().jobs.map((j) => ({ ...j, wasPaused: true })),
    } as never);
    await engageBrake();
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}")).toMatchObject({ intake: true, issues: [1, 2], uncertain: false });
  });

  it("drops a run whose record no longer verifies from the release, and says to check it", async () => {
    ready();
    vi.mocked(api.sendIntervention)
      .mockResolvedValueOnce({ ok: true, signalled: [101], failed: [] } as never)
      .mockResolvedValueOnce({ ok: false, signalled: [], failed: [], refused: "stale pid: the process started after the job" } as never);
    await engageBrake();
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(items()).toEqual(["#2: could no longer be confirmed as this run's pipeline. Check it in Runs."]);
    expect(brake().getAttribute("aria-pressed")).toBe("false");
  });

  it("applies one brake at a time: a second engage while one is in flight is refused", async () => {
    ready();
    let answer: (v: unknown) => void = () => {};
    vi.mocked(api.emergencyBrake).mockReturnValueOnce(new Promise((r) => (answer = r)) as never);
    const first = engageBrake();
    // In flight: shown, and remembered as unanswered in case the page closes now.
    expect(stateEl().textContent).toBe("Emergency brake: waiting for the dashboard server to answer…");
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}")).toMatchObject({ uncertain: true });
    await engageBrake();
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
    expect(toastText()).toMatch(/already being applied/);
    answer(brakeOk());
    await first;
    expect(toastText()).toBe("Emergency brake engaged: intake paused; all 2 running runs paused (5 processes).");
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}")).toMatchObject({ issues: [1, 2], uncertain: false });
  });

  it("refuses a brake while another tab's brake or release is in flight", async () => {
    ready();
    localStorage.setItem("sw-brake-busy", JSON.stringify({ tab: "other", until: Date.now() + 60_000 }));
    window.dispatchEvent(new StorageEvent("storage", { key: "sw-brake-busy" }));
    expect(brake().querySelector(".label-long")?.textContent).toBe("Brake: waiting");
    brake().click();
    expect(dialog().open).toBe(false);
    expect(toastText()).toMatch(/already being applied or released/);
    await engageBrake();
    expect(api.emergencyBrake).not.toHaveBeenCalled();
    // A marker left by a tab that closed mid-request expires.
    localStorage.setItem("sw-brake-busy", JSON.stringify({ tab: "other", until: Date.now() - 1 }));
    await engageBrake();
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
  });

  /** Web Locks shared by every tab: `other` holds the lock as another tab would. */
  function fakeLocks() {
    let held = false;
    let waiters: (() => void)[] = [];
    const free = () => {
      held = false;
      const w = waiters;
      waiters = [];
      for (const f of w) f();
    };
    const request = async (_name: string, opts: LockOptions, cb: (lock: unknown) => unknown) => {
      if (opts.mode === "shared") {
        while (held) await new Promise<void>((r) => waiters.push(r));
        return cb({});
      }
      if (held) return cb(null);
      held = true;
      try {
        return await cb({});
      } finally {
        free();
      }
    };
    Object.defineProperty(navigator, "locks", { value: { request }, configurable: true });
    return { other: () => (held = true), free, held: () => held };
  }
  const noLocks = () => Reflect.deleteProperty(navigator, "locks");

  it("refuses a brake while another tab holds the lock, even before its marker is seen", async () => {
    const locks = fakeLocks();
    try {
      ready();
      // Both tabs confirmed in the same instant: the other tab's marker has not reached this one.
      locks.other();
      await engageBrake();
      expect(api.emergencyBrake).not.toHaveBeenCalled();
      expect(api.pauseIntakeForBrake).not.toHaveBeenCalled();
      expect(toastText()).toMatch(/already being applied or released/);
      expect(localStorage.getItem("sw-brake")).toBeNull();
      locks.free();
      // Free: this tab's brake runs while holding the lock.
      let answer: (v: unknown) => void = () => {};
      vi.mocked(api.emergencyBrake).mockReturnValueOnce(new Promise((r) => (answer = r)) as never);
      const first = engageBrake();
      await flush();
      expect(locks.held()).toBe(true);
      answer(brakeOk());
      await first;
      expect(locks.held()).toBe(false);
      expect(toastText()).toBe("Emergency brake engaged: intake paused; all 2 running runs paused (5 processes).");
    } finally {
      noLocks();
    }
  });

  it("refuses a release while another tab holds the lock", async () => {
    ready();
    await engageBrake();
    const locks = fakeLocks();
    try {
      button(stateEl(), "Release brake…").click();
      await flush();
      locks.other();
      button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
      await flush();
      expect(api.sendIntervention).not.toHaveBeenCalled();
      expect(api.daemonControl).not.toHaveBeenCalled();
      expect(toastText()).toMatch(/already being applied or released/);
      expect(brake().getAttribute("aria-pressed")).toBe("true");
    } finally {
      noLocks();
    }
  });

  it("stops waiting when the tab that sent the brake closes mid-request, and shows it unconfirmed", async () => {
    const locks = fakeLocks();
    try {
      ready();
      // Another tab sent a brake: it recorded the attempt as unanswered and holds the lock.
      locks.other();
      localStorage.setItem("sw-brake", JSON.stringify({ intake: false, issues: [], at: Date.now(), partial: true, uncertain: true, intakeUncertain: true }));
      localStorage.setItem("sw-brake-busy", JSON.stringify({ tab: "other", until: Date.now() + 90_000 }));
      window.dispatchEvent(new StorageEvent("storage", { key: "sw-brake-busy" }));
      expect(brake().querySelector(".label-long")?.textContent).toBe("Brake: waiting");
      // That tab closes: the browser releases its lock; its marker is left behind.
      locks.free();
      await flush();
      expect(localStorage.getItem("sw-brake-busy")).toBeNull();
      expect(brake().querySelector(".label-long")?.textContent).toBe("Brake unconfirmed");
      expect(stateEl().textContent).toMatch(/^Brake unconfirmed since .* · intake may be paused · runs may be paused/);
      expect(button(stateEl(), "Retry brake…")).toBeTruthy();
    } finally {
      noLocks();
    }
  });

  it("without Web Locks, stops waiting when another tab's marker expires", () => {
    ready();
    localStorage.setItem("sw-brake", JSON.stringify({ intake: false, issues: [], at: Date.now(), partial: true, uncertain: true, intakeUncertain: true }));
    localStorage.setItem("sw-brake-busy", JSON.stringify({ tab: "other", until: Date.now() + 90_000 }));
    window.dispatchEvent(new StorageEvent("storage", { key: "sw-brake-busy" }));
    expect(stateEl().textContent).toBe("Emergency brake: waiting for the dashboard server to answer…");
    vi.advanceTimersByTime(90_100);
    expect(brake().querySelector(".label-long")?.textContent).toBe("Brake unconfirmed");
    expect(button(stateEl(), "Retry brake…")).toBeTruthy();
  });

  it("forgets 'intake was already paused' once a retry pauses intake itself", async () => {
    ready();
    vi.mocked(api.pauseIntakeForBrake).mockResolvedValueOnce({ ok: true, wasPaused: true });
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: [
        { issue: 1, pid: 101, signalled: [101], failed: [], wasPaused: false },
        { issue: 2, pid: 201, signalled: [], failed: [], refused: "not running" },
      ],
    } as never);
    await engageBrake();
    expect(stateEl().textContent).toMatch(/intake was already paused/);
    // Intake was resumed outside the dashboard; the retry pauses it.
    vi.mocked(api.pauseIntakeForBrake).mockResolvedValueOnce({ ok: true, wasPaused: false });
    await engageBrake();
    expect(toastText()).toBe("Emergency brake engaged: intake paused; all 2 running runs paused (5 processes).");
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}")).toMatchObject({ intake: true, intakeAlready: false });
    brake().click();
    await flush();
    expect(document.querySelector("dialog.confirm-dialog p")?.textContent).toBe(
      "This resumes daemon intake and the 2 runs this brake paused (#1, #2). Runs paused another way stay paused.",
    );
  });

  it("sends nothing when another tab changed the brake while the Release dialog was open", async () => {
    ready();
    await engageBrake();
    brake().click();
    await flush();
    const release = document.querySelector("dialog.confirm-dialog") as HTMLElement;
    expect(release.querySelector("p")?.textContent).toMatch(/the 2 runs this brake paused \(#1, #2\)/);
    // Another tab's retry adds a run this dialog never listed.
    const rec = JSON.parse(localStorage.getItem("sw-brake") ?? "{}");
    localStorage.setItem("sw-brake", JSON.stringify({ ...rec, issues: [...rec.issues, 3] }));
    window.dispatchEvent(new StorageEvent("storage", { key: "sw-brake" }));
    button(release, "Release brake").click();
    await flush();
    expect(api.sendIntervention).not.toHaveBeenCalled();
    expect(api.daemonControl).not.toHaveBeenCalled();
    expect(toastText()).toBe("The brake changed while this was open, so nothing was sent. Check it and try again.");
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}").issues).toEqual([1, 2, 3]);
  });

  it("sends nothing when another tab's answer was lost while the Release dialog was open, and says so", async () => {
    ready();
    await engageBrake();
    brake().click();
    await flush();
    const rec = JSON.parse(localStorage.getItem("sw-brake") ?? "{}");
    localStorage.setItem("sw-brake", JSON.stringify({ ...rec, partial: true, uncertain: true }));
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(api.sendIntervention).not.toHaveBeenCalled();
    expect(toastText()).toMatch(/^The brake changed while this was open, so nothing was sent/);
  });

  it("does not re-send a brake from a dialog left open across another tab's brake", async () => {
    ready();
    brake().click();
    expect(dialog().open).toBe(true);
    // Another tab engaged meanwhile.
    localStorage.setItem("sw-brake", JSON.stringify({ intake: true, issues: [1, 2], at: Date.now() }));
    (document.getElementById("emergency-confirm") as HTMLButtonElement).click();
    await flush();
    expect(api.emergencyBrake).not.toHaveBeenCalled();
    expect(api.pauseIntakeForBrake).not.toHaveBeenCalled();
    expect(toastText()).toMatch(/^The brake changed while this was open, so nothing was sent/);
  });

  it("removes an alert whose Retry is refused because the brake changed, leaving the status line's", async () => {
    ready();
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: [
        { issue: 1, pid: 101, signalled: [101], failed: [], wasPaused: false },
        { issue: 2, pid: 201, signalled: [], failed: [], refused: "not running" },
      ],
    } as never);
    await engageBrake();
    const rec = JSON.parse(localStorage.getItem("sw-brake") ?? "{}");
    localStorage.setItem("sw-brake", JSON.stringify({ ...rec, issues: [1, 3] }));
    button(alertEl(), "Retry brake").click();
    await flush();
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
    expect(toastText()).toMatch(/^The brake changed while this was open, so nothing was sent/);
    expect(alertEl().hidden).toBe(true);
    expect(button(stateEl(), "Retry brake…")).toBeTruthy();
  });

  it("still offers Release when the browser blocks site data (storage throws)", async () => {
    // As Chrome does with site data blocked: reading `localStorage` itself throws.
    const original = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      get() {
        throw new DOMException("The operation is insecure.", "SecurityError");
      },
    });
    try {
      ready();
      await engageBrake();
      expect(brake().getAttribute("aria-pressed")).toBe("true");
      brake().click();
      await flush();
      const release = document.querySelector("dialog.confirm-dialog") as HTMLElement;
      expect(release.querySelector("p")?.textContent).toMatch(/^This resumes daemon intake and the 2 runs this brake paused/);
      button(release, "Release brake").click();
      await flush();
      expect(vi.mocked(api.sendIntervention).mock.calls).toEqual([
        [1, "resume"],
        [2, "resume"],
      ]);
      expect(api.daemonControl).toHaveBeenCalledWith("resume");
    } finally {
      if (original) Object.defineProperty(globalThis, "localStorage", original);
    }
  });

  it("merges a release into the record as it is when the answer arrives", async () => {
    ready();
    await engageBrake();
    let answer: (v: unknown) => void = () => {};
    vi.mocked(api.daemonControl).mockReturnValueOnce(new Promise((r) => (answer = r)) as never);
    vi.mocked(api.sendIntervention).mockResolvedValue({ ok: true, signalled: [1], failed: [] } as never);
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    // Meanwhile the stored record gained a run this release does not cover.
    const rec = JSON.parse(localStorage.getItem("sw-brake") ?? "{}");
    localStorage.setItem("sw-brake", JSON.stringify({ ...rec, issues: [...rec.issues, 3] }));
    answer({ ok: true });
    await flush();
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}")).toMatchObject({ intake: false, issues: [3] });
  });

  it("follows another tab: its release clears this tab's engaged state", async () => {
    ready();
    await engageBrake();
    expect(brake().getAttribute("aria-pressed")).toBe("true");
    localStorage.removeItem("sw-brake");
    window.dispatchEvent(new StorageEvent("storage", { key: "sw-brake" }));
    expect(brake().getAttribute("aria-pressed")).toBe("false");
    expect(stateEl().hidden).toBe(true);
  });

  it("starts from the stored record, so another tab's brake is never taken for someone else's pause", async () => {
    ready();
    // Another tab engaged after this one loaded (no event seen yet).
    localStorage.setItem("sw-brake", JSON.stringify({ intake: true, issues: [1, 2], at: Date.now() }));
    vi.mocked(api.pauseIntakeForBrake).mockResolvedValueOnce({ ok: true, wasPaused: true });
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: brakeOk().jobs.map((j) => ({ ...j, wasPaused: true })),
    } as never);
    await engageBrake();
    expect(toastText()).toBe("Emergency brake engaged: intake paused; all 2 running runs paused (5 processes).");
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}")).toMatchObject({ intake: true, issues: [1, 2] });
  });

  it("refuses a second engage from the button before any confirmation while one is in flight", async () => {
    ready();
    let answer: (v: unknown) => void = () => {};
    vi.mocked(api.emergencyBrake).mockReturnValueOnce(new Promise((r) => (answer = r)) as never);
    const first = engageBrake();
    brake().click();
    expect(dialog().open).toBe(false);
    expect(toastText()).toMatch(/already being applied/);
    expect(brake().querySelector(".label-long")?.textContent).toBe("Brake: waiting");
    answer(brakeOk());
    await first;
  });

  it("does not claim to have paused runs that were all already paused", async () => {
    ready();
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: brakeOk().jobs.map((j) => ({ ...j, wasPaused: true })),
    } as never);
    await engageBrake();
    expect(toastText()).toBe(
      "Emergency brake engaged: intake paused; all 2 running runs were already paused and stay paused on release.",
    );
  });

  it("offers no Retry release when nothing is left to release", async () => {
    ready();
    vi.mocked(api.sendIntervention)
      .mockResolvedValueOnce({ ok: false, signalled: [], failed: [], refused: "stale pid: the process started after the job" } as never)
      .mockResolvedValueOnce({ ok: true, signalled: [201], failed: [] } as never);
    await engageBrake();
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(button(alertEl(), "Retry release")).toBeUndefined();
    expect(alertEl().textContent).toMatch(/Next: Check the runs listed above in Runs\./);
  });

  it("after a release whose answers were lost, says it may be resumed, never that it is still paused", async () => {
    ready();
    await engageBrake();
    vi.mocked(api.daemonControl).mockRejectedValueOnce(new TypeError("Failed to fetch"));
    vi.mocked(api.sendIntervention)
      .mockResolvedValueOnce({ ok: true, signalled: [101], failed: [] } as never)
      .mockRejectedValueOnce(new TypeError("Failed to fetch"));
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(items()).toEqual([
      "Intake: not confirmed resumed. The dashboard server did not answer the release; it may have acted.",
      "#2: not confirmed resumed. The dashboard server did not answer the release; it may have acted.",
    ]);
    const line = stateEl().textContent ?? "";
    expect(line).toMatch(/^Brake release unconfirmed since .* · intake may be resumed · 1 run may be resumed · the last release got no answer/);
    expect(line).not.toMatch(/intake paused|paused by it/);
    expect(brake().getAttribute("aria-pressed")).toBe("mixed");
    // Retrying the release (no second confirmation) settles it.
    vi.mocked(api.sendIntervention).mockResolvedValueOnce({ ok: true, signalled: [201], failed: [] } as never);
    button(stateEl(), "Retry release").click();
    await flush();
    expect(toastText()).toBe("Emergency brake released: intake resumed; 1 run resumed.");
    expect(brake().getAttribute("aria-pressed")).toBe("false");
  });

  it("keeps a lost release unconfirmed when its retry is refused: a refusal confirms nothing", async () => {
    ready();
    await engageBrake();
    vi.mocked(api.daemonControl).mockRejectedValueOnce(new TypeError("Failed to fetch"));
    vi.mocked(api.sendIntervention)
      .mockRejectedValueOnce(new TypeError("Failed to fetch"))
      .mockResolvedValueOnce({ ok: true, signalled: [201], failed: [] } as never);
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    const refused = () => Object.assign(new Error("HTTP 403"), { status: 403 });
    vi.mocked(api.daemonControl).mockRejectedValueOnce(refused());
    vi.mocked(api.sendIntervention).mockRejectedValueOnce(refused());
    button(stateEl(), "Retry release").click();
    await flush();
    const line = stateEl().textContent ?? "";
    expect(line).toMatch(/intake may be resumed · 1 run may be resumed/);
    expect(line).not.toMatch(/intake paused|paused by it/);
    expect(brake().getAttribute("aria-pressed")).toBe("mixed");
    expect(button(stateEl(), "Retry brake…")).toBeUndefined();
  });

  it("records a release as unconfirmed before sending it, so a closed page cannot claim still paused", async () => {
    ready();
    await engageBrake();
    let answer: (v: unknown) => void = () => {};
    vi.mocked(api.daemonControl).mockReturnValueOnce(new Promise((r) => (answer = r)) as never);
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}")).toMatchObject({ releaseUncertain: true });
    // A second release while this one is in flight is refused before any confirmation.
    brake().click();
    await flush();
    expect(document.querySelector("dialog.confirm-dialog")).toBeNull();
    expect(toastText()).toMatch(/already being applied or released/);
    answer({ ok: true });
    await flush();
    expect(brake().getAttribute("aria-pressed")).toBe("false");
  });

  it("says a request the page itself blocked was not sent, not that the server refused it", async () => {
    ready();
    vi.mocked(api.emergencyBrake).mockRejectedValueOnce(new Error("Not connected: actions need a live connection to the server."));
    await engageBrake();
    expect(items()).toContain(
      "Runs: not confirmed paused. The brake was not sent: Not connected: actions need a live connection to the server.",
    );
  });

  it("counts a run whose pipeline is gone (the pane shell outlived it) as ended on release", async () => {
    ready();
    vi.mocked(api.sendIntervention)
      .mockResolvedValueOnce({ ok: true, signalled: [101], failed: [] } as never)
      .mockResolvedValueOnce({ ok: false, signalled: [], failed: [], refused: "no pipeline for #2 under this process" } as never);
    await engageBrake();
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(toastText()).toBe("Emergency brake released: intake resumed; 1 run resumed; #2 had already ended.");
    expect(brake().getAttribute("aria-pressed")).toBe("false");
  });

  it("keeps a run whose record no longer verifies in the release when a continue failed", async () => {
    ready();
    vi.mocked(api.sendIntervention)
      .mockResolvedValueOnce({ ok: true, signalled: [101], failed: [] } as never)
      .mockResolvedValueOnce({ ok: false, signalled: [], failed: [{ pid: 202, error: "EPERM" }], refused: "stale pid: the process started after the job" } as never);
    await engageBrake();
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(items()).toEqual(["#2: not resumed."]);
    expect(button(alertEl(), "Retry release")).toBeTruthy();
  });

  it("keeps an ended run in the release when what the brake froze in it could not be continued", async () => {
    ready();
    vi.mocked(api.sendIntervention)
      .mockResolvedValueOnce({ ok: true, signalled: [101], failed: [] } as never)
      .mockResolvedValueOnce({ ok: false, signalled: [], failed: [{ pid: 202, error: "EPERM" }], refused: "not running" } as never);
    await engageBrake();
    button(stateEl(), "Release brake…").click();
    await flush();
    button(document.querySelector("dialog.confirm-dialog") as HTMLElement, "Release brake").click();
    await flush();
    expect(items()).toEqual(["#2: not resumed."]);
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}").issues).toEqual([2]);
    expect(button(alertEl(), "Retry release")).toBeTruthy();
  });

  it("engages nothing when everything was already paused, and says so", async () => {
    ready();
    vi.mocked(api.pauseIntakeForBrake).mockResolvedValueOnce({ ok: true, wasPaused: true });
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      ...brakeOk(),
      jobs: brakeOk().jobs.map((j) => ({ ...j, wasPaused: true })),
    } as never);
    await engageBrake();
    expect(toastText()).toBe("Emergency brake: intake and all 2 running runs were already paused; nothing changed.");
    expect(brake().getAttribute("aria-pressed")).toBe("false");
    expect(stateEl().hidden).toBe(true);
  });

  it("stops claiming intake stays paused once it is resumed from Triage", async () => {
    ready();
    const pauseBtn = document.createElement("button");
    pauseBtn.id = "daemon-btn-pause";
    const badge = document.createElement("span");
    badge.id = "daemon-status-badge";
    document.body.append(pauseBtn, badge);
    // The server reports intake paused, so the Triage control offers Resume intake.
    vi.mocked(api.fetchDaemonConfig).mockResolvedValueOnce({ paused: true } as never);
    setupHeader();
    await flush();
    vi.mocked(api.pauseIntakeForBrake).mockResolvedValueOnce({ ok: true, wasPaused: true });
    await engageBrake();
    expect(stateEl().textContent).toMatch(/intake was already paused/);
    pauseBtn.click();
    await flush();
    expect(api.daemonControl).toHaveBeenCalledWith("resume");
    expect(stateEl().textContent).toMatch(/· intake resumed · 2 runs paused by it/);
    brake().click();
    await flush();
    expect(document.querySelector("dialog.confirm-dialog p")?.textContent).toBe(
      "This resumes the 2 runs this brake paused (#1, #2). Runs paused another way stay paused.",
    );
  });

  it("labels the alert's brake action Release while the brake is engaged", async () => {
    ready();
    const banner = document.createElement("div");
    banner.id = "alert-banner";
    document.body.append(banner);
    store.set("alertDismissed", false);
    store.set("alertsCache", [{ type: "failure_spike", severity: "critical", message: "3 runs failed" }] as never);
    store.set("currentUser", { username: "ada", role: "operator" });
    expect(Array.from(banner.querySelectorAll("button")).map((b) => b.textContent)).toContain("Emergency brake…");
    await engageBrake();
    expect(Array.from(banner.querySelectorAll("button")).map((b) => b.textContent)).toContain("Release brake…");
  });

  it("is still engaged after a reload, and a viewer cannot release it", () => {
    localStorage.setItem("sw-brake", JSON.stringify({ intake: true, issues: [4], at: Date.now() }));
    setupHeader();
    expect(brake().getAttribute("aria-pressed")).toBe("true");
    expect(stateEl().textContent).toMatch(/intake paused · 1 run paused by it/);
    store.set("connected", true);
    store.set("currentUser", { username: "v", role: "viewer" });
    brake().click();
    expect(document.querySelector("dialog.confirm-dialog")).toBeNull();
    expect(toastText()).toMatch(/[Vv]iewer/);
  });

  it("drops a run resumed by hand from what the brake will release", async () => {
    ready();
    vi.mocked(api.sendIntervention).mockResolvedValue({ ok: true, signalled: [101], failed: [] } as never);
    await engageBrake();
    await sendRunAction(1, "resume");
    expect(stateEl().textContent).toMatch(/· 1 run paused by it/);
    expect(JSON.parse(localStorage.getItem("sw-brake") ?? "{}").issues).toEqual([2]);
  });
});

describe("never-connected page", () => {
  it("moves from Connecting to Reconnecting on the first failed attempt, then Offline", async () => {
    vi.useFakeTimers();
    // A fresh header and store: connection state is module-level.
    vi.resetModules();
    const { setupHeader, STALE_MS } = await import("./header");
    const { store } = await import("../core/state");
    const api = await import("../core/api");
    const doc = new DOMParser().parseFromString(
      `<span id="conn"><span id="conn-text"></span></span><span id="conn-live"></span><div id="toast" hidden></div>`,
      "text/html",
    );
    document.body.replaceChildren(...Array.from(doc.body.childNodes));
    store.set("connected", false);
    vi.mocked(api.fetchMe).mockReturnValue(new Promise(() => {}));
    setupHeader();
    const state = () => document.getElementById("conn")?.dataset.state;
    expect(state()).toBe("connecting");
    // ws.ts adds its banner on the first close, without changing "connected".
    const banner = document.createElement("div");
    banner.id = "offline-banner";
    banner.append(document.createElement("span"), document.createElement("span"));
    document.body.append(banner);
    vi.advanceTimersByTime(1000);
    expect(state()).toBe("reconnecting");
    expect(banner.children[1].textContent).toMatch(/^Reconnecting · no data yet\./);
    vi.advanceTimersByTime(STALE_MS + 1000);
    expect(state()).toBe("offline");
    expect(document.getElementById("conn-text")?.textContent).toMatch(/^Offline since /);
    expect(banner.children[1].textContent).toMatch(/^Offline since /);
    vi.useRealTimers();
  });
});

describe("daemonStopBody", () => {
  it("says running runs are terminated, with the count", () => {
    expect(daemonStopBody(2)).toContain("All 2 running runs are terminated; they cannot be resumed from the dashboard.");
    expect(daemonStopBody(1)).toContain("All 1 running run is terminated");
    expect(daemonStopBody(0)).toContain("No runs are running now");
  });
});
