import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

vi.mock("../core/api", () => ({
  fetchMe: vi.fn(() => Promise.resolve({ username: "Ada Lovelace", role: "operator" })),
  fetchDaemonConfig: vi.fn(() => Promise.resolve({})),
  fetchAlerts: vi.fn(() => Promise.resolve({ alerts: [] })),
  emergencyBrake: vi.fn(() => Promise.resolve({ paused: 2, queued: 0 })),
  sendIntervention: vi.fn(() => Promise.resolve({ ok: true })),
  daemonControl: vi.fn(() => Promise.resolve({})),
}));

import { connectionState, connectionText, connectionShort, initialsFor, STALE_MS, setupHeader } from "./header";
import { store } from "../core/state";
import * as api from "../core/api";

const T = new Date(2026, 9, 25, 14, 2, 0).getTime();

describe("connectionState", () => {
  it("is connecting before the first message", () => {
    expect(connectionState({ connected: false, disconnectedAt: null, lastDataAt: null, now: T })).toBe("connecting");
  });

  it("is live while connected and data is fresh", () => {
    expect(connectionState({ connected: true, disconnectedAt: null, lastDataAt: T - 2000, now: T })).toBe("live");
  });

  it("is stale while connected when data stops arriving", () => {
    expect(connectionState({ connected: true, disconnectedAt: null, lastDataAt: T - STALE_MS - 1, now: T })).toBe("stale");
  });

  it("is reconnecting just after a drop, then stale", () => {
    const base = { connected: false, lastDataAt: T - 5000 };
    expect(connectionState({ ...base, disconnectedAt: T - 1000, now: T })).toBe("reconnecting");
    expect(connectionState({ ...base, disconnectedAt: T - STALE_MS - 1, now: T })).toBe("stale");
  });
});

describe("connection labels", () => {
  const live = { connected: true, disconnectedAt: null, lastDataAt: T - 3000, now: T };
  const stale = { connected: false, disconnectedAt: T - 60000, lastDataAt: new Date(2026, 9, 25, 14, 1).getTime(), now: T };

  it("give the data age when live and the last data time when stale", () => {
    expect(connectionText("live", live)).toBe("Live, updated 3s ago");
    expect(connectionText("stale", stale)).toBe("Stale since 14:01");
    expect(connectionText("stale", { ...stale, lastDataAt: null })).toBe("Stale, no data yet");
    expect(connectionText("reconnecting", stale)).toBe("Reconnecting");
  });

  it("have a short text form, so state is never shown by colour alone", () => {
    expect(connectionShort("live", live)).toBe("Live");
    expect(connectionShort("stale", stale)).toBe("Stale 14:01");
    expect(connectionShort("reconnecting", stale)).toBe("Retrying");
    expect(connectionShort("connecting", stale)).toBe("Connecting");
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
    setupHeader();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.clearAllMocks();
  });

  const dialog = () => document.getElementById("emergency-modal") as HTMLDialogElement;

  it("is unavailable with a reason while not connected, from any entry point", () => {
    const brake = document.getElementById("emergency-brake") as HTMLButtonElement;
    expect(brake.getAttribute("aria-disabled")).toBe("true");
    expect(brake.title).toMatch(/Not connected/);
    brake.click();
    expect(dialog().open).toBe(false);
    (document.getElementById("emergency-confirm") as HTMLButtonElement).click();
    expect(api.emergencyBrake).not.toHaveBeenCalled();
  });

  it("opens a confirmation with Cancel focused once connected, and sends only on confirm", async () => {
    store.set("connected", true);
    store.set("fleetState", { pipelines: [{ issue: 1 }, { issue: 2 }] } as never);
    const brake = document.getElementById("emergency-brake") as HTMLButtonElement;
    expect(brake.hasAttribute("aria-disabled")).toBe(false);
    brake.click();
    expect(dialog().open).toBe(true);
    expect(document.activeElement?.textContent).toBe("Cancel");
    expect(document.getElementById("emergency-active-count")?.textContent).toBe("2");
    expect(api.emergencyBrake).not.toHaveBeenCalled();
    (document.getElementById("emergency-confirm") as HTMLButtonElement).click();
    expect(api.emergencyBrake).toHaveBeenCalledTimes(1);
    await vi.runOnlyPendingTimersAsync();
  });
});
