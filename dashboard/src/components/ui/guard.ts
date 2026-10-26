// UI side of the action gate in core/guard.ts: the reason is shown as an error toast.

import { actionBlockReason, onActionBlocked, type GateOptions } from "../../core/guard";
import { toast } from "./toast";

export { actionBlockReason, markRoleUnavailable } from "../../core/guard";

onActionBlocked((reason) => toast(reason, "error"));

export function canAct(opts?: GateOptions): boolean {
  return actionBlockReason(opts) === undefined;
}

/** True when the action may go ahead; otherwise shows the reason and returns false. */
export function guardAction(opts?: GateOptions): boolean {
  const reason = actionBlockReason(opts);
  if (reason) toast(reason, "error");
  return reason === undefined;
}
