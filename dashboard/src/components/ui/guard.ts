// UI side of the action gate in core/guard.ts: the reason is shown as an error toast.

import { actionBlockReason, onActionBlocked } from "../../core/guard";
import { toast } from "./toast";

export { actionBlockReason, markRoleUnavailable } from "../../core/guard";

onActionBlocked((reason) => toast(reason, "error"));

export function canAct(): boolean {
  return actionBlockReason() === undefined;
}

/** True when the action may go ahead; otherwise shows the reason and returns false. */
export function guardAction(): boolean {
  const reason = actionBlockReason();
  if (reason) toast(reason, "error");
  return reason === undefined;
}
