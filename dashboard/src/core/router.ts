// Destination routing: six destinations in a tablist, legacy hashes redirect to their new home,
// and every registered view keeps its init/render/destroy lifecycle and error boundary.

import { store } from "./state";
import type { FleetState, TabId, View } from "../types/api";

export type DestinationId =
  | "triage"
  | "runs"
  | "agents"
  | "safety"
  | "cost"
  | "settings";

export interface Destination {
  readonly id: DestinationId;
  readonly label: string;
  /** Second key of the `g` shortcut (`g t` goes to Triage). */
  readonly key: string;
  /** Views mounted in this destination until T3 rebuilds it, first view primary. */
  readonly views: readonly TabId[];
}

export const DESTINATIONS: readonly Destination[] = [
  { id: "triage", label: "Triage", key: "t", views: ["overview"] },
  { id: "runs", label: "Runs", key: "r", views: ["pipelines", "timeline"] },
  { id: "agents", label: "Agents", key: "a", views: ["agents", "machines"] },
  { id: "safety", label: "Safety", key: "s", views: ["activity"] },
  { id: "cost", label: "Cost and DORA", key: "c", views: ["metrics", "insights"] },
  { id: "settings", label: "Settings", key: "d", views: ["team"] },
];

/** Retired views kept reachable on their old hash, outside the tab bar, until T4 deletes them. */
export const LEGACY_ROUTES: readonly TabId[] = [
  "fleet-map",
  "pipeline-theater",
  "agent-cockpit",
  "shipyard",
];

export type Route =
  | { kind: "destination"; dest: DestinationId; section?: TabId }
  | { kind: "legacy"; view: TabId };

const DEFAULT_ROUTE: Route = { kind: "destination", dest: "triage" };

/** Maps a hash (with or without `#`) to a route. Old view hashes land on the destination that hosts the view. */
export function resolveRoute(hash: string): Route | null {
  const id = hash.replace(/^#/, "");
  if (!id) return null;
  const dest = DESTINATIONS.find((d) => d.id === id);
  if (dest) return { kind: "destination", dest: dest.id };
  if ((LEGACY_ROUTES as readonly string[]).includes(id)) {
    return { kind: "legacy", view: id as TabId };
  }
  const host = DESTINATIONS.find((d) => (d.views as readonly string[]).includes(id));
  if (!host) return null;
  return id === host.views[0]
    ? { kind: "destination", dest: host.id }
    : { kind: "destination", dest: host.id, section: id as TabId };
}

export function routeKey(route: Route): string {
  return route.kind === "legacy" ? route.view : route.dest;
}

export function viewsFor(route: Route): readonly TabId[] {
  if (route.kind === "legacy") return [route.view];
  return DESTINATIONS.find((d) => d.id === route.dest)?.views ?? [];
}

const views = new Map<TabId, View>();
const initializedViews = new Set<TabId>();
const routeListeners = new Set<(route: Route) => void>();
let current: Route | null = null;

export function registerView(tabId: TabId, view: View): void {
  views.set(tabId, view);
}

export function getRegisteredViews(): Map<TabId, View> {
  return views;
}

export function currentRoute(): Route {
  return current ?? DEFAULT_ROUTE;
}

export function isViewActive(tabId: TabId): boolean {
  return viewsFor(currentRoute()).includes(tabId);
}

export function onRouteChange(fn: (route: Route) => void): () => void {
  routeListeners.add(fn);
  return () => routeListeners.delete(fn);
}

/** Navigates to a destination, a legacy view or an old view id. Unknown targets are ignored. */
export function switchTab(target: string): void {
  const route = resolveRoute(target);
  if (route) navigate(route);
}

function navigate(route: Route): void {
  const prev = current;
  const key = routeKey(route);
  // A redirect replaces the history entry so Back does not bounce through the old hash.
  if (location.hash.replace(/^#/, "") !== key) {
    history.replaceState(null, "", "#" + key);
  }
  if (prev && routeKey(prev) === key) {
    revealSection(route);
    return;
  }
  current = route;
  const next = viewsFor(route);
  for (const id of prev ? viewsFor(prev) : []) {
    if (!next.includes(id)) destroyView(id);
  }
  store.set("activeTab", next[0] ?? "overview");
  syncChrome(route);
  const fleetState = store.get("fleetState");
  for (const id of next) mountView(id, fleetState);
  revealSection(route);
  routeListeners.forEach((fn) => fn(route));
}

function syncChrome(route: Route): void {
  const key = routeKey(route);
  document.querySelectorAll<HTMLElement>('[role="tab"][data-dest]').forEach((tab) => {
    const on = tab.dataset.dest === key;
    tab.setAttribute("aria-selected", String(on));
    tab.tabIndex = on ? 0 : -1;
  });
  // On a legacy route no tab is selected; keep the first tab reachable.
  if (route.kind === "legacy") {
    const first = document.querySelector<HTMLElement>('[role="tab"][data-dest]');
    if (first) first.tabIndex = 0;
  }
  document.querySelectorAll<HTMLElement>("[data-route]").forEach((panel) => {
    panel.hidden = panel.dataset.route !== key;
  });
}

function revealSection(route: Route): void {
  if (route.kind !== "destination" || !route.section) return;
  const el = document.getElementById("panel-" + route.section);
  if (el && typeof el.scrollIntoView === "function") el.scrollIntoView({ block: "start" });
}

function destroyView(id: TabId): void {
  const view = views.get(id);
  if (view && initializedViews.has(id)) {
    view.destroy();
    initializedViews.delete(id);
  }
}

function mountView(id: TabId, fleetState: FleetState | null): void {
  const view = views.get(id);
  if (!view) return;
  try {
    if (!initializedViews.has(id)) {
      view.init();
      initializedViews.add(id);
    }
    if (fleetState) view.render(fleetState);
  } catch (err) {
    console.error(`[Error Boundary] View "${id}" failed:`, err);
    showViewError(id, err);
  }
}

export function renderActiveView(): void {
  const fleetState = store.get("fleetState");
  if (!fleetState) return;
  for (const id of viewsFor(currentRoute())) mountView(id, fleetState);
}

function showViewError(id: TabId, err: unknown): void {
  const panel = document.getElementById("panel-" + id);
  if (!panel || panel.querySelector(".tab-error-boundary")) return;
  const box = document.createElement("div");
  box.className = "tab-error-boundary";
  box.setAttribute("role", "alert");
  const title = document.createElement("strong");
  title.textContent = "This section failed to load";
  const msg = document.createElement("pre");
  msg.className = "error-boundary-msg";
  msg.textContent = err instanceof Error ? err.message : String(err);
  const retry = document.createElement("button");
  retry.type = "button";
  retry.className = "btn sm error-boundary-retry";
  retry.textContent = "Retry";
  retry.addEventListener("click", () => {
    box.remove();
    initializedViews.delete(id);
    mountView(id, store.get("fleetState"));
  });
  box.append(title, msg, retry);
  panel.prepend(box);
}

export function setupRouter(): void {
  document.querySelectorAll<HTMLElement>('[role="tab"][data-dest]').forEach((tab) => {
    tab.addEventListener("click", () => switchTab(tab.dataset.dest ?? ""));
  });
  navigate(resolveRoute(location.hash) ?? DEFAULT_ROUTE);
  window.addEventListener("hashchange", () => {
    const route = resolveRoute(location.hash);
    if (route) navigate(route);
  });
  store.subscribe("fleetState", () => renderActiveView());
}

