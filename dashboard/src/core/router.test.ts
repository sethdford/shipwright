import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";
import type { View } from "../types/api";

type MockView = View & {
  init: ReturnType<typeof vi.fn>;
  render: ReturnType<typeof vi.fn>;
  destroy: ReturnType<typeof vi.fn>;
};

function mockView(): MockView {
  return { init: vi.fn(), render: vi.fn(), destroy: vi.fn() };
}

function mount(html: string): void {
  const doc = new DOMParser().parseFromString(html, "text/html");
  document.body.replaceChildren(...Array.from(doc.body.childNodes));
}

const SHELL = `
  <div role="tablist" id="dest-tabs">
    <button role="tab" data-dest="triage" aria-selected="true" tabindex="0">Triage</button>
    <button role="tab" data-dest="runs" aria-selected="false" tabindex="-1">Runs</button>
    <button role="tab" data-dest="agents" aria-selected="false" tabindex="-1">Agents</button>
    <button role="tab" data-dest="safety" aria-selected="false" tabindex="-1">Safety</button>
    <button role="tab" data-dest="cost" aria-selected="false" tabindex="-1">Cost and DORA</button>
    <button role="tab" data-dest="settings" aria-selected="false" tabindex="-1">Settings</button>
  </div>
  <section data-route="triage"><div id="panel-overview"></div></section>
  <section data-route="runs" hidden><div id="panel-pipelines"></div><div id="panel-timeline"></div></section>
  <section data-route="agents" hidden><div id="panel-agents"></div><div id="panel-machines"></div></section>
  <section data-route="safety" hidden><div id="panel-activity"></div></section>
  <section data-route="cost" hidden><div id="panel-metrics"></div><div id="panel-insights"></div></section>
  <section data-route="settings" hidden><div id="panel-team"></div></section>
  <section data-route="shipyard" hidden><div id="panel-shipyard"></div></section>
`;

describe("router", () => {
  let store: typeof import("./state").store;
  let router: typeof import("./router");

  beforeEach(async () => {
    mount(SHELL);
    history.replaceState(null, "", "#");
    vi.resetModules();
    store = (await import("./state")).store;
    router = await import("./router");
  });

  afterEach(() => vi.restoreAllMocks());

  const selected = () =>
    Array.from(document.querySelectorAll('[role="tab"][aria-selected="true"]')).map((t) =>
      t.getAttribute("data-dest"),
    );
  const visible = () =>
    Array.from(document.querySelectorAll<HTMLElement>("[data-route]"))
      .filter((p) => !p.hidden)
      .map((p) => p.dataset.route);

  describe("destination map", () => {
    it("has the six destinations in tab order with unique g-keys", () => {
      expect(router.DESTINATIONS.map((d) => d.id)).toEqual(["triage", "runs", "agents", "safety", "cost", "settings"]);
      expect(router.DESTINATIONS.map((d) => d.key)).toEqual(["t", "r", "a", "s", "c", "d"]);
    });

    it("hosts every non-retired legacy view exactly once", () => {
      const hosted = router.DESTINATIONS.flatMap((d) => d.views);
      expect(new Set(hosted).size).toBe(hosted.length);
      expect([...hosted].sort()).toEqual(
        ["activity", "agents", "insights", "machines", "metrics", "overview", "pipelines", "team", "timeline"].sort(),
      );
    });
  });

  describe("resolveRoute", () => {
    it.each([
      ["#triage", { kind: "destination", dest: "triage" }],
      ["runs", { kind: "destination", dest: "runs" }],
      ["#overview", { kind: "destination", dest: "triage" }],
      ["#pipelines", { kind: "destination", dest: "runs" }],
      ["#timeline", { kind: "destination", dest: "runs", section: "timeline" }],
      ["#agents", { kind: "destination", dest: "agents" }],
      ["#machines", { kind: "destination", dest: "agents", section: "machines" }],
      ["#activity", { kind: "destination", dest: "safety" }],
      ["#metrics", { kind: "destination", dest: "cost" }],
      ["#insights", { kind: "destination", dest: "cost", section: "insights" }],
      ["#team", { kind: "destination", dest: "settings" }],
      ["#shipyard", { kind: "legacy", view: "shipyard" }],
      ["#fleet-map", { kind: "legacy", view: "fleet-map" }],
      ["#pipeline-theater", { kind: "legacy", view: "pipeline-theater" }],
      ["#agent-cockpit", { kind: "legacy", view: "agent-cockpit" }],
    ])("%s resolves to its home", (hash, route) => {
      expect(router.resolveRoute(hash)).toEqual(route);
    });

    it("returns null for empty and unknown hashes", () => {
      expect(router.resolveRoute("")).toBeNull();
      expect(router.resolveRoute("#")).toBeNull();
      expect(router.resolveRoute("#nope")).toBeNull();
    });
  });

  describe("switchTab", () => {
    beforeEach(() => router.setupRouter());

    it("starts on Triage when the hash is empty", () => {
      expect(selected()).toEqual(["triage"]);
      expect(visible()).toEqual(["triage"]);
      expect(location.hash).toBe("#triage");
    });

    it("selects the tab, shows only its panel and moves the tab stop", () => {
      router.switchTab("cost");
      expect(selected()).toEqual(["cost"]);
      expect(visible()).toEqual(["cost"]);
      const tabs = document.querySelectorAll<HTMLElement>('[role="tab"]');
      expect(Array.from(tabs).map((t) => t.tabIndex)).toEqual([-1, -1, -1, -1, 0, -1]);
      expect(location.hash).toBe("#cost");
    });

    it("redirects an old view id and rewrites the hash", () => {
      router.switchTab("machines");
      expect(selected()).toEqual(["agents"]);
      expect(location.hash).toBe("#agents");
      expect(store.get("activeTab")).toBe("agents");
    });

    it("shows a retired view behind its old hash with no tab selected", () => {
      router.switchTab("shipyard");
      expect(selected()).toEqual([]);
      expect(visible()).toEqual(["shipyard"]);
      expect(document.querySelector<HTMLElement>('[data-dest="triage"]')?.tabIndex).toBe(0);
    });

    it("ignores unknown targets", () => {
      router.switchTab("nope");
      expect(selected()).toEqual(["triage"]);
    });

    it("notifies route listeners", () => {
      const fn = vi.fn();
      router.onRouteChange(fn);
      router.switchTab("safety");
      expect(fn).toHaveBeenCalledWith({ kind: "destination", dest: "safety" });
    });
  });

  describe("view lifecycle", () => {
    it("mounts every view a destination hosts and destroys them on leave", () => {
      const pipelines = mockView();
      const timeline = mockView();
      router.registerView("pipelines", pipelines);
      router.registerView("timeline", timeline);
      router.setupRouter();
      router.switchTab("runs");
      expect(pipelines.init).toHaveBeenCalledTimes(1);
      expect(timeline.init).toHaveBeenCalledTimes(1);
      expect(router.isViewActive("timeline")).toBe(true);
      router.switchTab("safety");
      expect(pipelines.destroy).toHaveBeenCalledTimes(1);
      expect(timeline.destroy).toHaveBeenCalledTimes(1);
      expect(router.isViewActive("timeline")).toBe(false);
    });

    it("does not remount when an alias names the current destination", () => {
      const overview = mockView();
      router.registerView("overview", overview);
      router.setupRouter();
      router.switchTab("overview");
      expect(overview.init).toHaveBeenCalledTimes(1);
      expect(overview.destroy).not.toHaveBeenCalled();
    });

    it("renders with fleet state on mount and on each update", () => {
      const metrics = mockView();
      router.registerView("metrics", metrics);
      router.setupRouter();
      const state = { pipelines: [] } as never;
      store.set("fleetState", state);
      router.switchTab("cost");
      expect(metrics.render).toHaveBeenCalledWith(state);
      store.set("fleetState", { pipelines: [] } as never);
      expect(metrics.render).toHaveBeenCalledTimes(2);
    });

    it("follows hashchange, including old hashes", () => {
      router.setupRouter();
      history.replaceState(null, "", "#team");
      window.dispatchEvent(new HashChangeEvent("hashchange"));
      expect(selected()).toEqual(["settings"]);
      expect(location.hash).toBe("#settings");
    });

    it("opens on the destination named by the initial hash", () => {
      history.replaceState(null, "", "#insights");
      router.setupRouter();
      expect(selected()).toEqual(["cost"]);
    });

    it("navigates on tab click", () => {
      router.setupRouter();
      document.querySelector<HTMLElement>('[data-dest="agents"]')?.click();
      expect(selected()).toEqual(["agents"]);
    });
  });

  describe("error boundary", () => {
    beforeEach(() => vi.spyOn(console, "error").mockImplementation(() => {}));

    it("shows an alert with the message as text and a Retry that remounts", () => {
      const broken = mockView();
      broken.init.mockImplementationOnce(() => {
        throw new Error("boom <b>");
      });
      router.registerView("activity", broken);
      router.setupRouter();
      router.switchTab("safety");
      const box = document.querySelector("#panel-activity .tab-error-boundary");
      expect(box?.getAttribute("role")).toBe("alert");
      expect(box?.querySelector("pre")?.textContent).toBe("boom <b>");
      expect(box?.querySelector("b")).toBeNull();
      box?.querySelector<HTMLButtonElement>("button")?.click();
      expect(broken.init).toHaveBeenCalledTimes(2);
      expect(document.querySelector("#panel-activity .tab-error-boundary")).toBeNull();
    });

    it("does not stack boundaries and reports non-Error throws", () => {
      const broken = mockView();
      broken.render.mockImplementation(() => {
        throw "plain";
      });
      router.registerView("team", broken);
      router.setupRouter();
      store.set("fleetState", { pipelines: [] } as never);
      router.switchTab("settings");
      store.set("fleetState", { pipelines: [] } as never);
      const boxes = document.querySelectorAll("#panel-team .tab-error-boundary");
      expect(boxes).toHaveLength(1);
      expect(boxes[0].querySelector("pre")?.textContent).toBe("plain");
    });
  });
});
