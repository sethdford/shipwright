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
  engageBrake,
  initialsFor,
  setupHeader,
  STALE_MS,
} from "./header";
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
      "Offline since 14:01. Showing data from 14:01. Actions are off until reconnected; the emergency brake still works and reports what it paused.",
    );
    expect(bannerText("reconnecting", { ...off, lastDataAt: null })).toBe(
      "Reconnecting. No data received yet. Actions are off until reconnected; the emergency brake still works and reports what it paused.",
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
    mount(`
      <span id="conn"><span id="conn-text"></span></span><span id="conn-live"></span>
      <button id="emergency-brake">Emergency brake</button>
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
  const ready = () => {
    store.set("connected", true);
    store.set("currentUser", { username: "ada", role: "operator" });
    store.set("fleetState", { pipelines: [{ issue: 1 }, { issue: 2 }] } as never);
  };

  const operator = () => store.set("currentUser", { username: "ada", role: "operator" });

  it("works while disconnected: the brake is exempt from the connection gate", async () => {
    operator();
    expect(brake().hasAttribute("aria-disabled")).toBe(false);
    brake().click();
    expect(dialog().open).toBe(true);
    expect(document.getElementById("brake-desc")?.textContent).toMatch(/how many are running is unknown here/);
    await engageBrake();
    expect(api.pauseIntakeForBrake).toHaveBeenCalledTimes(1);
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
    expect(toastText()).toBe("Emergency brake engaged: intake paused; all 2 running pipelines paused (5 processes).");
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
    expect(document.getElementById("brake-desc")?.textContent).toMatch(/each running pipeline \(2 now\)/);
    expect(api.emergencyBrake).not.toHaveBeenCalled();
  });

  it("is incomplete, naming the runs, when any job's tree was not fully paused", async () => {
    ready();
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({
      paused: 0,
      running: 2,
      queued: 0,
      jobs: [
        { issue: 1, pid: 101, signalled: [], failed: [], refused: "stale pid: the process started after the job" },
        { issue: 2, pid: 201, signalled: [201], failed: [{ pid: 202, error: "EPERM" }] },
      ],
    } as never);
    await engageBrake();
    expect(toastText()).toBe(
      "Emergency brake incomplete: #1 stale pid: the process started after the job; #2 1 process not paused. Check the daemon now.",
    );
    expect(document.getElementById("toast")?.getAttribute("role")).toBe("alert");
  });

  it("never reports success when the intake pause fails, and still sends both", async () => {
    ready();
    vi.mocked(api.pauseIntakeForBrake).mockRejectedValueOnce(new Error("HTTP 500"));
    await engageBrake();
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
    expect(toastText()).toMatch(/^Emergency brake incomplete: pausing intake failed .*HTTP 500/);
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
    expect(banner.children[1].textContent).toMatch(/^Reconnecting\. No data received yet\./);
    vi.advanceTimersByTime(STALE_MS + 1000);
    expect(state()).toBe("offline");
    expect(document.getElementById("conn-text")?.textContent).toMatch(/^Offline since /);
    expect(banner.children[1].textContent).toMatch(/^Offline since /);
    vi.useRealTimers();
  });
});

describe("daemonStopBody", () => {
  it("says running pipelines are terminated, with the count", () => {
    expect(daemonStopBody(2)).toContain("All 2 running pipelines are terminated; they cannot be resumed from the dashboard.");
    expect(daemonStopBody(1)).toContain("All 1 running pipeline is terminated");
    expect(daemonStopBody(0)).toContain("No pipelines are running now");
  });
});
