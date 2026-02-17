// Tab navigation with hash routing and view lifecycle

import { store } from "./state";
import type { TabId, View, FleetState } from "../types/api";

const views = new Map<TabId, View>();
const initializedViews = new Set<TabId>();

const VALID_TABS: TabId[] = [
  "overview",
  "agents",
  "pipelines",
  "timeline",
  "activity",
  "metrics",
  "machines",
  "insights",
  "team",
  "fleet-map",
  "pipeline-theater",
  "agent-cockpit",
];

let teamRefreshTimer: ReturnType<typeof setInterval> | null = null;

export function registerView(tabId: TabId, view: View): void {
  views.set(tabId, view);
}

export function switchTab(tab: TabId): void {
  const prev = store.get("activeTab");
  if (prev === tab) return;

  // Destroy previous view
  const prevView = views.get(prev);
  if (prevView && initializedViews.has(prev)) {
    prevView.destroy();
    initializedViews.delete(prev);
  }

  // Clear team refresh timer if leaving team tab
  if (prev === "team" && teamRefreshTimer) {
    clearInterval(teamRefreshTimer);
    teamRefreshTimer = null;
  }

  store.set("activeTab", tab);
  location.hash = "#" + tab;

  // Update tab button classes
  const btns = document.querySelectorAll(".tab-btn");
  btns.forEach((btn) => {
    if (btn.getAttribute("data-tab") === tab) {
      btn.classList.add("active");
    } else {
      btn.classList.remove("active");
    }
  });

  // Update panel visibility
  const panels = document.querySelectorAll(".tab-panel");
  panels.forEach((panel) => {
    if (panel.id === "panel-" + tab) {
      panel.classList.add("active");
    } else {
      panel.classList.remove("active");
    }
  });

  // Initialize the new view with error boundary
  const view = views.get(tab);
  if (view && !initializedViews.has(tab)) {
    try {
      view.init();
      initializedViews.add(tab);
    } catch (err) {
      console.error(`[Error Boundary] Tab "${tab}" init failed:`, err);
      showTabError(tab, err);
    }
  }

  // Render with current data
  const fleetState = store.get("fleetState");
  if (fleetState && view) {
    try {
      view.render(fleetState);
    } catch (err) {
      console.error(`[Error Boundary] Tab "${tab}" render failed:`, err);
      showTabError(tab, err);
    }
  }
}

export function renderActiveView(): void {
  const tab = store.get("activeTab");
  const view = views.get(tab);
  const fleetState = store.get("fleetState");
  if (!view || !fleetState) return;

  try {
    if (!initializedViews.has(tab)) {
      view.init();
      initializedViews.add(tab);
    }
    view.render(fleetState);
  } catch (err) {
    console.error(`[Error Boundary] Tab "${tab}" render failed:`, err);
    showTabError(tab, err);
  }
}

function showTabError(tab: TabId, err: unknown): void {
  const panel = document.getElementById("panel-" + tab);
  if (!panel) return;
  const msg = err instanceof Error ? err.message : String(err);
  const existing = panel.querySelector(".tab-error-boundary");
  if (existing) return; // don't stack errors
  const div = document.createElement("div");
  div.className = "tab-error-boundary";
  div.innerHTML =
    `<div class="error-boundary-content">` +
    `<span class="error-boundary-icon">\u26A0</span>` +
    `<div><strong>This tab encountered an error</strong>` +
    `<pre class="error-boundary-msg">${msg.replace(/</g, "&lt;")}</pre></div>` +
    `<button class="btn-sm error-boundary-retry">Retry</button></div>`;
  panel.prepend(div);
  const retryBtn = div.querySelector(".error-boundary-retry");
  if (retryBtn) {
    retryBtn.addEventListener("click", () => {
      div.remove();
      initializedViews.delete(tab);
      const v = views.get(tab);
      if (v) {
        try {
          v.init();
          initializedViews.add(tab);
          const state = store.get("fleetState");
          if (state) v.render(state);
        } catch (retryErr) {
          console.error(
            `[Error Boundary] Retry failed for "${tab}":`,
            retryErr,
          );
          showTabError(tab, retryErr);
        }
      }
    });
  }
}

export function setupRouter(): void {
  // Tab button click handlers
  const btns = document.querySelectorAll(".tab-btn");
  btns.forEach((btn) => {
    btn.addEventListener("click", () => {
      const tab = btn.getAttribute("data-tab") as TabId;
      if (tab) switchTab(tab);
    });
  });

  // Hash-based routing
  const hash = location.hash.replace("#", "") as TabId;
  if (VALID_TABS.includes(hash)) {
    switchTab(hash);
  } else {
    // Default to overview
    const activeTab = store.get("activeTab");
    const view = views.get(activeTab);
    if (view && !initializedViews.has(activeTab)) {
      view.init();
      initializedViews.add(activeTab);
    }
  }

  window.addEventListener("hashchange", () => {
    const h = location.hash.replace("#", "") as TabId;
    if (VALID_TABS.includes(h) && h !== store.get("activeTab")) {
      switchTab(h);
    }
  });

  // Subscribe to fleet state changes to re-render active view
  store.subscribe("fleetState", () => {
    renderActiveView();
  });
}

export function getRegisteredViews(): Map<TabId, View> {
  return views;
}
