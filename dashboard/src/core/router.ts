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

  // Initialize the new view
  const view = views.get(tab);
  if (view && !initializedViews.has(tab)) {
    view.init();
    initializedViews.add(tab);
  }

  // Render with current data
  const fleetState = store.get("fleetState");
  if (fleetState && view) {
    view.render(fleetState);
  }
}

export function renderActiveView(): void {
  const tab = store.get("activeTab");
  const view = views.get(tab);
  const fleetState = store.get("fleetState");
  if (!view || !fleetState) return;

  if (!initializedViews.has(tab)) {
    view.init();
    initializedViews.add(tab);
  }

  view.render(fleetState);
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
