// One gate for every request that changes runs or the fleet. It fails closed: nothing is
// sent until the socket is live and /api/me has loaded a role that may act. api.ts checks it
// for every non-GET request, so view-owned buttons are covered too.

import { store } from "./state";

let roleUnavailable = false;
let notify: ((reason: string) => void) | null = null;

/** Called when /api/me fails, so the reason says so instead of "still loading". */
export function markRoleUnavailable(): void {
  roleUnavailable = true;
}

/** Lets the UI show the reason when a request is refused (core cannot import components). */
export function onActionBlocked(fn: (reason: string) => void): void {
  notify = fn;
}

export function actionBlockReason(): string | undefined {
  if (!store.get("connected")) return "Not connected: actions need a live connection to the server.";
  const user = store.get("currentUser");
  if (!user) {
    return roleUnavailable
      ? "Your role could not be loaded, so actions are off."
      : "Your role is still loading, so actions are off.";
  }
  if (user.role === "viewer") return "Viewers cannot act on runs or the fleet.";
  return undefined;
}

/** Throws (and notifies) when actions are blocked. */
export function assertCanAct(): void {
  const reason = actionBlockReason();
  if (reason === undefined) return;
  notify?.(reason);
  throw new Error(reason);
}
