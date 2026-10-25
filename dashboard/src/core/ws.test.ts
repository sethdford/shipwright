import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";

describe("WebSocket module", () => {
  let ws: typeof import("./ws");
  let store: typeof import("./state");

  // Mock WebSocket
  class MockWebSocket {
    url: string;
    onopen: (() => void) | null = null;
    onclose: (() => void) | null = null;
    onerror: (() => void) | null = null;
    onmessage: ((e: { data: string }) => void) | null = null;

    constructor(url: string) {
      this.url = url;
      MockWebSocket.instances.push(this);
    }

    close() {}

    static instances: MockWebSocket[] = [];
    static reset() {
      MockWebSocket.instances = [];
    }
  }

  beforeEach(async () => {
    vi.resetModules();
    vi.useFakeTimers();

    // Set up DOM elements the ws module expects
    document.body.innerHTML = `
      <div id="connection-dot" class="connection-dot offline"></div>
      <span id="connection-text">OFFLINE</span>
      <div id="stale-data-banner" style="display:none"></div>
      <span id="stale-data-age"></span>
      <div class="main"></div>
    `;

    // Mock WebSocket
    MockWebSocket.reset();
    (global as any).WebSocket = MockWebSocket;

    // Mock location
    Object.defineProperty(window, "location", {
      value: {
        protocol: "http:",
        host: "localhost:18767",
        href: "http://localhost:18767/#triage",
        hash: "",
      },
      writable: true,
    });

    // Import fresh
    store = await import("./state");
    ws = await import("./ws");
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  describe("connect", () => {
    it("creates a WebSocket with the correct URL", () => {
      ws.connect();
      expect(MockWebSocket.instances).toHaveLength(1);
      expect(MockWebSocket.instances[0].url).toBe("ws://localhost:18767/ws");
    });

    it("uses wss: on an https page and drops the page path and hash", () => {
      window.location.href = "https://fleet.example.test/sub/page?x=1#runs";
      ws.connect();
      expect(MockWebSocket.instances.at(-1)?.url).toBe("wss://fleet.example.test/ws");
    });

    it("stores the WebSocket reference", () => {
      ws.connect();
      expect(ws.getWebSocket()).toBeTruthy();
    });
  });

  describe("onopen", () => {
    it("sets connected state to true", () => {
      ws.connect();
      const instance = MockWebSocket.instances[0];
      instance.onopen?.();

      expect(store.store.get("connected")).toBe(true);
      expect(store.store.get("connectedAt")).toBeGreaterThan(0);
    });

    it("updates connection status to LIVE", () => {
      ws.connect();
      MockWebSocket.instances[0].onopen?.();

      const dot = document.getElementById("connection-dot");
      expect(dot?.className).toContain("live");
    });
  });

  describe("onclose", () => {
    it("sets connected state to false", () => {
      ws.connect();
      const instance = MockWebSocket.instances[0];
      instance.onopen?.();
      instance.onclose?.();

      expect(store.store.get("connected")).toBe(false);
      expect(store.store.get("connectedAt")).toBeNull();
    });

    it("updates connection status to OFFLINE", () => {
      ws.connect();
      const instance = MockWebSocket.instances[0];
      instance.onclose?.();

      const dot = document.getElementById("connection-dot");
      expect(dot?.className).toContain("offline");
    });

    it("schedules reconnection", () => {
      ws.connect();
      const instance = MockWebSocket.instances[0];
      instance.onclose?.();

      // Should schedule a reconnect
      vi.advanceTimersByTime(1500);
      // A new WebSocket should have been created
      expect(MockWebSocket.instances.length).toBeGreaterThanOrEqual(2);
    });

    it("uses exponential backoff for reconnection", () => {
      ws.connect();

      // First close - 1s delay
      MockWebSocket.instances[0].onclose?.();
      vi.advanceTimersByTime(1100);
      expect(MockWebSocket.instances.length).toBe(2);

      // Second close - 2s delay
      MockWebSocket.instances[1].onclose?.();
      vi.advanceTimersByTime(1100);
      expect(MockWebSocket.instances.length).toBe(2); // not yet
      vi.advanceTimersByTime(1100);
      expect(MockWebSocket.instances.length).toBe(3); // now
    });
  });

  describe("onmessage", () => {
    it("parses JSON and updates fleet state", () => {
      ws.connect();
      const instance = MockWebSocket.instances[0];
      instance.onopen?.();

      const mockState = {
        pipelines: [{ issue: 42, status: "building" }],
        machines: [],
      };
      instance.onmessage?.({ data: JSON.stringify(mockState) });

      expect(store.store.get("fleetState")).toEqual(mockState);
      expect(store.store.get("firstRender")).toBe(false);
    });

    it("handles malformed JSON gracefully", () => {
      ws.connect();
      const instance = MockWebSocket.instances[0];
      instance.onopen?.();

      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});
      instance.onmessage?.({ data: "not json{" });

      // Should not crash, fleet state should remain null
      expect(store.store.get("fleetState")).toBeNull();
      consoleSpy.mockRestore();
    });
  });

  describe("stale data detection", () => {
    it("shows stale banner after 30s without data", () => {
      ws.connect();
      const instance = MockWebSocket.instances[0];
      instance.onopen?.();

      // Send one message to set lastDataTime
      instance.onmessage?.({ data: JSON.stringify({ pipelines: [] }) });

      // Advance time by 35 seconds
      vi.advanceTimersByTime(35000);

      const banner = document.getElementById("stale-data-banner");
      expect(banner?.style.display).not.toBe("none");
    });
  });

  describe("offline banner", () => {
    it("shows offline banner on disconnect", () => {
      ws.connect();
      MockWebSocket.instances[0].onclose?.();

      const banner = document.getElementById("offline-banner");
      expect(banner).toBeTruthy();
      expect(banner?.style.display).not.toBe("none");
    });

    it("hides offline banner on reconnect", () => {
      ws.connect();
      MockWebSocket.instances[0].onclose?.();

      // Reconnect
      vi.advanceTimersByTime(1500);
      MockWebSocket.instances[1].onopen?.();

      const banner = document.getElementById("offline-banner");
      expect(banner?.style.display).toBe("none");
    });
  });
});
