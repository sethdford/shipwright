import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

vi.mock("../core/api", () => ({
  fetchMe: vi.fn(() => Promise.resolve({ username: "Ada Lovelace", role: "operator" })),
  fetchDaemonConfig: vi.fn(() => Promise.resolve({})),
  fetchAlerts: vi.fn(() => Promise.resolve({ alerts: [] })),
  emergencyBrake: vi.fn(() => Promise.resolve({ paused: 2, queued: 0 })),
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
      "Offline since 14:01. Showing data from 14:01. Emergency brake unavailable until reconnected.",
    );
    expect(bannerText("reconnecting", { ...off, lastDataAt: null })).toBe(
      "Reconnecting. No data received yet. Emergency brake unavailable until reconnected.",
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
        <strong id="emergency-active-count">0</strong>
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

  it("is unavailable with a reason while not connected, from any entry point", () => {
    expect(brake().getAttribute("aria-disabled")).toBe("true");
    expect(brake().title).toMatch(/Not connected/);
    brake().click();
    expect(dialog().open).toBe(false);
    (document.getElementById("emergency-confirm") as HTMLButtonElement).click();
    expect(api.emergencyBrake).not.toHaveBeenCalled();
  });

  it("fails closed until the role has loaded", () => {
    store.set("connected", true);
    expect(brake().getAttribute("aria-disabled")).toBe("true");
    expect(brake().title).toMatch(/role/);
    brake().click();
    expect(dialog().open).toBe(false);
  });

  it("stays off, and says why, when /api/me fails", async () => {
    vi.mocked(api.fetchMe).mockRejectedValueOnce(new Error("HTTP 500"));
    setupHeader();
    await Promise.resolve();
    await Promise.resolve();
    store.set("connected", true);
    expect(brake().getAttribute("aria-disabled")).toBe("true");
    expect(brake().title).toBe("Your role could not be loaded, so actions are off.");
  });

  it("waits for live data: connected with a role but no run list yet is not enough", () => {
    store.set("connected", true);
    store.set("currentUser", { username: "ada", role: "operator" });
    expect(brake().title).toMatch(/Waiting for live data/);
    brake().click();
    expect(dialog().open).toBe(false);
  });

  it("is refused for viewers", () => {
    store.set("connected", true);
    store.set("currentUser", { username: "v", role: "viewer" });
    expect(brake().title).toMatch(/Viewers/);
  });

  it("confirms with Cancel focused, then pauses intake and the running pipelines", async () => {
    ready();
    expect(brake().hasAttribute("aria-disabled")).toBe(false);
    brake().click();
    expect(dialog().open).toBe(true);
    expect(document.activeElement?.textContent).toBe("Cancel");
    expect(document.getElementById("emergency-active-count")?.textContent).toBe("2");
    expect(api.emergencyBrake).not.toHaveBeenCalled();
    await engageBrake();
    expect(api.daemonControl).toHaveBeenCalledWith("pause");
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
    expect(toastText()).toBe("Emergency brake engaged: intake paused; pause signal sent to 2 of 2 running pipelines.");
  });

  it("reports an incomplete brake when fewer runs were paused than are running", async () => {
    ready();
    vi.mocked(api.emergencyBrake).mockResolvedValueOnce({ paused: 0, queued: 0 } as never);
    await engageBrake();
    expect(toastText()).toBe(
      "Emergency brake incomplete: intake paused; pause signal sent to 0 of 2 running pipelines. Check the daemon now.",
    );
  });

  it("never reports success when either half fails, and still attempts both", async () => {
    ready();
    vi.mocked(api.daemonControl).mockRejectedValueOnce(new Error("HTTP 500"));
    await engageBrake();
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
    expect(toastText()).toMatch(/^Emergency brake incomplete: pausing intake failed .*HTTP 500.*pause signal sent to 2 of 2 running pipelines/);
    expect(document.getElementById("toast")?.getAttribute("role")).toBe("alert");
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
