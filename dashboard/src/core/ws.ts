// WebSocket connection with automatic reconnection, stale data indicator, offline resilience

import { store } from "./state";
import type { FleetState } from "../types/api";

let ws: WebSocket | null = null;
let reconnectDelay = 1000;
let connectionTimer: ReturnType<typeof setInterval> | null = null;
let lastDataTime = 0;
let staleTimer: ReturnType<typeof setInterval> | null = null;
let reconnectAttempts = 0;

function startConnectionTimer(): void {
  stopConnectionTimer();
  connectionTimer = setInterval(() => {
    const connectedAt = store.get("connectedAt");
    if (connectedAt) {
      const elapsed = Math.floor((Date.now() - connectedAt) / 1000);
      const h = String(Math.floor(elapsed / 3600)).padStart(2, "0");
      const m = String(Math.floor((elapsed % 3600) / 60)).padStart(2, "0");
      const s = String(elapsed % 60).padStart(2, "0");
      const el = document.getElementById("connection-text");
      if (el) el.textContent = `LIVE \u2014 ${h}:${m}:${s}`;
    }
  }, 1000);
}

function stopConnectionTimer(): void {
  if (connectionTimer) {
    clearInterval(connectionTimer);
    connectionTimer = null;
  }
}

function startStaleDataTimer(): void {
  if (staleTimer) clearInterval(staleTimer);
  staleTimer = setInterval(() => {
    if (!lastDataTime) return;
    const ageS = Math.floor((Date.now() - lastDataTime) / 1000);
    const banner = document.getElementById("stale-data-banner");
    if (ageS > 30 && banner) {
      banner.style.display = "";
      const ageEl = document.getElementById("stale-data-age");
      if (ageEl) {
        if (ageS < 60) ageEl.textContent = `${ageS}s`;
        else if (ageS < 3600)
          ageEl.textContent = `${Math.floor(ageS / 60)}m ${ageS % 60}s`;
        else
          ageEl.textContent = `${Math.floor(ageS / 3600)}h ${Math.floor((ageS % 3600) / 60)}m`;
      }
    } else if (banner) {
      banner.style.display = "none";
    }
  }, 5000);
}

function updateConnectionStatus(status: "LIVE" | "OFFLINE"): void {
  const dot = document.getElementById("connection-dot");
  const text = document.getElementById("connection-text");
  if (!dot || !text) return;
  if (status === "LIVE") {
    dot.className = "connection-dot live";
    text.textContent = "LIVE \u2014 00:00:00";
    reconnectAttempts = 0;
  } else {
    dot.className = "connection-dot offline";
    text.textContent = `OFFLINE (retry ${reconnectAttempts})`;
  }
}

function showOfflineBanner(show: boolean): void {
  let banner = document.getElementById("offline-banner");
  if (!banner && show) {
    banner = document.createElement("div");
    banner.id = "offline-banner";
    banner.className = "offline-banner";
    banner.innerHTML =
      `<span class="offline-icon">\u26A0</span>` +
      `<span>Connection lost. Data may be stale.</span>` +
      `<button class="btn-sm" id="manual-reconnect">Reconnect</button>`;
    const main = document.querySelector(".main");
    if (main) main.prepend(banner);
    document
      .getElementById("manual-reconnect")
      ?.addEventListener("click", () => {
        if (ws) {
          try {
            ws.close();
          } catch {}
        }
        reconnectDelay = 1000;
        reconnectAttempts = 0;
        connect();
      });
  }
  if (banner) banner.style.display = show ? "" : "none";
}

export function connect(): void {
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const wsUrl = `${protocol}//${location.host}/ws`;
  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    reconnectDelay = 1000;
    reconnectAttempts = 0;
    store.update({ connected: true, connectedAt: Date.now() });
    updateConnectionStatus("LIVE");
    startConnectionTimer();
    showOfflineBanner(false);
  };

  ws.onclose = () => {
    store.update({ connected: false, connectedAt: null });
    stopConnectionTimer();
    reconnectAttempts++;
    updateConnectionStatus("OFFLINE");
    showOfflineBanner(true);
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 30000);
  };

  ws.onerror = () => {};

  ws.onmessage = (e: MessageEvent) => {
    try {
      const data: FleetState = JSON.parse(e.data);
      lastDataTime = Date.now();
      store.update({
        fleetState: data,
        firstRender: false,
      });
    } catch (err) {
      console.error("Failed to parse message:", err);
    }
  };

  startStaleDataTimer();
}

export function getWebSocket(): WebSocket | null {
  return ws;
}
