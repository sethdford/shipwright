// One gate for every request that changes runs or the fleet. It fails closed: nothing is
// sent until the socket is live and /api/me has loaded a role that may act (operator or
// admin). api.ts checks it for every non-GET request, so view-owned buttons are covered too.
// This gate is client-side only; server-side role enforcement is #8720.

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

/** Only these roles may act. A missing, unknown or new role is refused (fail closed). */
const ACTING_ROLES = new Set(["operator", "admin"]);

export interface GateOptions {
  /**
   * The emergency brake is exempt from the connection check: it must work when the live
   * feed is stale or down, and it reports the real result of its request. Role still applies.
   */
  allowOffline?: boolean;
}

export function actionBlockReason(opts: GateOptions = {}): string | undefined {
  if (!opts.allowOffline && !store.get("connected")) {
    return "Not connected: actions need a live connection to the server.";
  }
  const user = store.get("currentUser");
  if (!user) {
    return roleUnavailable
      ? "Your role could not be loaded, so actions are off."
      : "Your role is still loading, so actions are off.";
  }
  if (user.role === "viewer") return "Viewers cannot act on runs or the fleet.";
  if (!ACTING_ROLES.has(String(user.role))) return "Your role does not allow actions on runs or the fleet.";
  return undefined;
}

/** Throws (and notifies) when actions are blocked. */
export function assertCanAct(opts: GateOptions = {}): void {
  const reason = actionBlockReason(opts);
  if (reason === undefined) return;
  notify?.(reason);
  throw new Error(reason);
}
