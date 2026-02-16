// WebSocket connection with automatic reconnection

import { store } from "./state";
import type { FleetState } from "../types/api";

let ws: WebSocket | null = null;
let reconnectDelay = 1000;
let connectionTimer: ReturnType<typeof setInterval> | null = null;

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

function updateConnectionStatus(status: "LIVE" | "OFFLINE"): void {
  const dot = document.getElementById("connection-dot");
  const text = document.getElementById("connection-text");
  if (!dot || !text) return;
  if (status === "LIVE") {
    dot.className = "connection-dot live";
    text.textContent = "LIVE \u2014 00:00:00";
  } else {
    dot.className = "connection-dot offline";
    text.textContent = "OFFLINE";
  }
}

export function connect(): void {
  const wsUrl = `ws://${location.host}/ws`;
  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    reconnectDelay = 1000;
    store.update({ connected: true, connectedAt: Date.now() });
    updateConnectionStatus("LIVE");
    startConnectionTimer();
  };

  ws.onclose = () => {
    store.update({ connected: false, connectedAt: null });
    stopConnectionTimer();
    updateConnectionStatus("OFFLINE");
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 10000);
  };

  ws.onerror = () => {};

  ws.onmessage = (e: MessageEvent) => {
    try {
      const data: FleetState = JSON.parse(e.data);
      store.update({
        fleetState: data,
        firstRender: false,
      });
    } catch (err) {
      console.error("Failed to parse message:", err);
    }
  };
}

export function getWebSocket(): WebSocket | null {
  return ws;
}
