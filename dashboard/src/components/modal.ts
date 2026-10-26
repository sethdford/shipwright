// Dialogs for intervention, bulk actions, machines, join links and notifications.
// Every dialog is a native <dialog> (focus trap, Esc, focus return); destructive actions
// confirm in a dialog that names the target, with Cancel focused.

import * as api from "../core/api";
import { store } from "../core/state";
import { isViewActive } from "../core/router";
import { h } from "./ui/dom";
import { openDialog, closeDialog, confirmDialog } from "./ui/dialog";
import { toast } from "./ui/toast";
import { guardAction } from "./ui/guard";
import { stageLabel } from "./ui/stage";

let interventionTarget: number | null = null;
let removeMachineTarget: string | null = null;
let workerUpdateTimer: ReturnType<typeof setTimeout> | null = null;

// Intervention Modal
export function setupInterventionModal(): void {
  const sendBtn = document.getElementById("modal-send");
  const msgEl = document.getElementById(
    "modal-message",
  ) as HTMLTextAreaElement | null;

  function closeModal() {
    closeDialog("intervention-modal");
    interventionTarget = null;
  }

  if (sendBtn) {
    sendBtn.addEventListener("click", () => {
      if (interventionTarget && msgEl?.value.trim() && guardAction()) {
        const issue = interventionTarget;
        api
          .sendIntervention(issue, "message", { message: msgEl.value.trim() })
          .then(() => toast(`Message sent to run #${issue}.`))
          .catch((err) => toast(`Message failed for run #${issue}: ${String(err)}`, "error"));
        closeModal();
      }
    });
  }
}

export function openInterventionModal(issue: number): void {
  interventionTarget = issue;
  const title = document.getElementById("modal-title");
  const msg = document.getElementById(
    "modal-message",
  ) as HTMLTextAreaElement | null;
  if (title) title.textContent = "Send a message to run #" + issue;
  if (msg) msg.value = "";
  openDialog("intervention-modal");
}

/**
 * Runs this page paused (pause, bulk pause, emergency brake) and has not resumed. The server
 * does not report paused state, so this is what the palette's Pause/Resume toggle goes by.
 */
export const pausedRuns = new Set<number>();

export type RunAction = "pause" | "resume" | "abort";
const ACTION_WORD: Record<RunAction, string> = { pause: "Pause", resume: "Resume", abort: "Stop" };
const DONE_WORD: Record<RunAction, string> = { pause: "paused", resume: "resumed", abort: "stopped" };
const processes = (n: number) => `${n} process${n === 1 ? "" : "es"}`;

const runListeners: Array<(issue: number, action: RunAction) => void> = [];
/** Called after a run action fully succeeded (the brake keeps its engaged list current). */
export function onRunAction(fn: (issue: number, action: RunAction) => void): void {
  runListeners.push(fn);
}

/**
 * The one path for run interventions: gated, and reported from what the server says it
 * signalled. A response that signalled nothing means the run is not running (or its PID was
 * refused), never success. Pause state is tracked only from fully signalled runs.
 */
export function sendRunAction(issue: number, action: RunAction): Promise<void> {
  if (!guardAction()) return Promise.resolve();
  const word = ACTION_WORD[action];
  return api
    .sendIntervention(issue, action)
    .then((res) => {
      const signalled = res.signalled ?? [];
      const failed = res.failed ?? [];
      if (signalled.length === 0) {
        const why =
          !res.refused || res.refused === "not running"
            ? "is not running"
            : `could not be confirmed as this run's pipeline (${res.refused})`;
        toast(`${word} did nothing: run #${issue} ${why}.`, "error");
        return;
      }
      if (failed.length > 0) {
        toast(`${word} incomplete for run #${issue}: ${processes(failed.length)} could not be signalled.`, "error");
        return;
      }
      if (res.refused) {
        // The run has ended, but resume continued what a pause had left frozen (subprocess-guards.ts).
        pausedRuns.delete(issue);
        toast(`Run #${issue} had already ended; continued ${processes(signalled.length)} its pause left frozen. Check the host.`, "error");
        return;
      }
      if (action === "pause") pausedRuns.add(issue);
      else pausedRuns.delete(issue);
      for (const fn of runListeners) fn(issue, action);
      const killed = res.killed?.length ? `, ${res.killed.length} killed after the grace period` : "";
      if (res.untraced) {
        // The run shares a process group it does not lead: anything that left its tree escaped.
        toast(`${word} incomplete for run #${issue}: ${processes(signalled.length)} stopped${killed}, but processes that left the run can't be traced. Check the host.`, "error");
        return;
      }
      const cont = res.continued?.length
        ? ` Continued ${processes(res.continued.length)} an earlier run left paused; check the host.`
        : "";
      toast(`Run #${issue} ${DONE_WORD[action]}: ${processes(signalled.length)}${killed}.${cont}`);
    })
    .catch((err) => toast(`${word} failed for run #${issue}: ${String(err)}`, "error"));
}

// The server signals the run's whole process tree: SIGTERM, then SIGKILL to anything still
// alive after a grace period (dashboard/services/subprocess-guards.ts stopTrees).
const STOP_OUTCOME =
  "Every process in the run gets a terminate signal, and anything still running a few seconds " +
  "later is killed. It cannot be resumed from the dashboard.";

/** Stop (abort) one run after a confirmation that names it. */
export async function confirmAbort(issue: number, stage?: string): Promise<void> {
  if (!guardAction()) return;
  const ok = await confirmDialog({
    title: `Stop run #${issue}?`,
    body: (stage ? `The run is in the ${stageLabel(stage)} stage. ` : "") + STOP_OUTCOME,
    confirmLabel: "Stop run",
    cancelLabel: "Keep run",
    danger: true,
  });
  if (ok) await sendRunAction(issue, "abort");
}

// Bulk Actions
export function setupBulkActions(): void {
  const pauseBtn = document.getElementById("bulk-pause");
  const resumeBtn = document.getElementById("bulk-resume");
  const abortBtn = document.getElementById("bulk-abort");

  if (pauseBtn) {
    pauseBtn.addEventListener("click", () => {
      const issues = Object.keys(store.get("selectedIssues"));
      if (guardAction()) issues.forEach((i) => void sendRunAction(Number(i), "pause"));
    });
  }

  if (resumeBtn) {
    resumeBtn.addEventListener("click", () => {
      const issues = Object.keys(store.get("selectedIssues"));
      if (guardAction()) issues.forEach((i) => void sendRunAction(Number(i), "resume"));
    });
  }

  if (abortBtn) {
    abortBtn.addEventListener("click", async () => {
      const issues = Object.keys(store.get("selectedIssues"));
      if (issues.length === 0 || !guardAction()) return;
      const ok = await confirmDialog({
        title: `Stop ${issues.length} run${issues.length === 1 ? "" : "s"}?`,
        body: "Runs " + issues.map((i) => "#" + i).join(", ") + ". " + STOP_OUTCOME,
        confirmLabel: "Stop runs",
        cancelLabel: "Keep runs",
        danger: true,
      });
      if (!ok) return;
      issues.forEach((i) => void sendRunAction(Number(i), "abort"));
      store.set("selectedIssues", {});
      updateBulkToolbar();
    });
  }
}

export function updateBulkToolbar(): void {
  const toolbar = document.getElementById("bulk-actions");
  if (!toolbar) return;
  const count = Object.keys(store.get("selectedIssues")).length;
  if (count === 0) {
    toolbar.style.display = "none";
    return;
  }
  toolbar.style.display = "";
  const countEl = document.getElementById("bulk-count");
  if (countEl) countEl.textContent = count + " selected";
}

// Machine Modals
export function setupMachinesModals(): void {
  const addBtn = document.getElementById("btn-add-machine");
  if (addBtn) addBtn.addEventListener("click", openAddMachineModal);

  const joinBtn = document.getElementById("btn-join-link");
  if (joinBtn) joinBtn.addEventListener("click", openJoinLinkModal);

  // Close and Cancel buttons carry data-close; openDialog wires them.
  bindClick("machine-modal-submit", submitAddMachine);
  bindClick("join-modal-generate", generateJoinLink);
  bindClick("join-copy-btn", copyJoinCommand);
  bindClick("remove-modal-confirm", executeRemoveMachine);
}

function bindClick(id: string, handler: () => void): void {
  const el = document.getElementById(id);
  if (el) el.addEventListener("click", handler);
}

function openAddMachineModal(): void {
  setVal("machine-name", "");
  setVal("machine-host", "");
  setVal("machine-ssh-user", "");
  setVal("machine-path", "");
  setVal("machine-workers", "4");
  setVal("machine-role", "worker");
  const err = document.getElementById("machine-modal-error");
  if (err) err.style.display = "none";
  openDialog("add-machine-modal");
}

function closeAddMachineModal(): void {
  closeDialog("add-machine-modal");
}

function submitAddMachine(): void {
  const name = getVal("machine-name").trim();
  const host = getVal("machine-host").trim();
  const sshUser = getVal("machine-ssh-user").trim();
  const swPath = getVal("machine-path").trim();
  const maxWorkers = parseInt(getVal("machine-workers"), 10) || 4;
  const role = getVal("machine-role");
  const errEl = document.getElementById("machine-modal-error");

  if (!name || !host) {
    if (errEl) {
      errEl.textContent = "Name and host are required";
      errEl.style.display = "";
    }
    return;
  }

  const body: Record<string, unknown> = {
    name,
    host,
    role,
    max_workers: maxWorkers,
  };
  if (sshUser) body.ssh_user = sshUser;
  if (swPath) body.shipwright_path = swPath;

  api
    .addMachine(body)
    .then(() => {
      closeAddMachineModal();
      refreshMachines();
    })
    .catch((err) => {
      if (errEl) {
        errEl.textContent = err.message || "Failed to register machine";
        errEl.style.display = "";
      }
    });
}

export function updateWorkerCount(name: string, value: string): void {
  if (workerUpdateTimer) clearTimeout(workerUpdateTimer);
  workerUpdateTimer = setTimeout(() => {
    api
      .updateMachine(name, { max_workers: parseInt(value, 10) })
      .then((updated) => {
        const card = document.getElementById("machine-card-" + name);
        if (card) {
          const countEl = card.querySelector(".workers-count");
          if (countEl)
            countEl.textContent =
              (updated.active_workers || 0) +
              " / " +
              (updated.max_workers || value);
        }
      })
      .catch((err) => console.error("Worker update failed:", err));
  }, 500);
}

export function machineHealthCheckAction(name: string): void {
  const card = document.getElementById("machine-card-" + name);
  if (card) {
    const checkBtn = card.querySelector(
      ".machine-action-btn",
    ) as HTMLButtonElement;
    if (checkBtn) {
      checkBtn.textContent = "Checking\u2026";
      checkBtn.disabled = true;
    }
  }

  api
    .machineHealthCheck(name)
    .then((result) => {
      if (result.machine && card) {
        const m = result.machine;
        const health = m.health || {};
        const healthRows = card.querySelectorAll(".machine-health-row");
        if (healthRows.length >= 3) {
          const statusEl = healthRows[0].querySelector(".health-status");
          if (statusEl) {
            statusEl.className =
              "health-status " +
              (health.daemon_running ? "running" : "stopped");
            statusEl.textContent = health.daemon_running
              ? "Running"
              : "Stopped";
          }
          const hbEl = healthRows[1].querySelector(".health-value");
          if (hbEl) hbEl.textContent = String(health.heartbeat_count || 0);
          const lastEl = healthRows[2].querySelector(".health-value");
          if (lastEl)
            lastEl.textContent = formatHbAge(health.last_heartbeat_s_ago);
        }
        const dot = card.querySelector(".presence-dot");
        if (dot) dot.className = "presence-dot " + (m.status || "offline");
      }
      resetCheckBtn(card);
    })
    .catch((err) => {
      console.error("Health check failed:", err);
      resetCheckBtn(card);
    });
}

function resetCheckBtn(card: HTMLElement | null): void {
  if (card) {
    const btn = card.querySelector(".machine-action-btn") as HTMLButtonElement;
    if (btn) {
      btn.textContent = "Check";
      btn.disabled = false;
    }
  }
}

function formatHbAge(age: number | undefined): string {
  if (typeof age !== "number" || age >= 9999) return "\u2014";
  if (age < 60) return age + "s ago";
  if (age < 3600) return Math.floor(age / 60) + "m ago";
  return Math.floor(age / 3600) + "h ago";
}

export function confirmMachineRemove(name: string): void {
  removeMachineTarget = name;
  const el = document.getElementById("remove-machine-name");
  if (el) el.textContent = name;
  openDialog("remove-machine-modal");
}

function executeRemoveMachine(): void {
  if (!removeMachineTarget) return;
  api
    .removeMachine(removeMachineTarget)
    .then(() => {
      closeDialog("remove-machine-modal");
      removeMachineTarget = null;
      refreshMachines();
    })
    .catch((err) => {
      closeDialog("remove-machine-modal");
      toast(`Could not remove ${removeMachineTarget ?? "the machine"}: ${String(err)}`, "error");
      removeMachineTarget = null;
    });
}

function openJoinLinkModal(): void {
  setVal("join-label", "");
  setVal("join-workers", "4");
  const cmdDisplay = document.getElementById("join-command-display");
  if (cmdDisplay) cmdDisplay.style.display = "none";
  const cmdText = document.getElementById("join-command-text");
  if (cmdText) cmdText.textContent = "";
  openDialog("join-link-modal");
}

function generateJoinLink(): void {
  const label = getVal("join-label").trim();
  const maxWorkers = parseInt(getVal("join-workers"), 10) || 4;
  const btn = document.getElementById(
    "join-modal-generate",
  ) as HTMLButtonElement;
  if (btn) {
    btn.textContent = "Generating\u2026";
    btn.disabled = true;
  }

  api
    .generateJoinToken({ label, max_workers: maxWorkers })
    .then((data) => {
      const cmdText = document.getElementById("join-command-text");
      if (cmdText) cmdText.textContent = data.join_cmd || "";
      const tokenText = document.getElementById("join-token-text");
      if (tokenText) tokenText.textContent = data.token || "";
      const cmdDisplay = document.getElementById("join-command-display");
      if (cmdDisplay) cmdDisplay.style.display = "";
      if (btn) {
        btn.textContent = "Generate";
        btn.disabled = false;
      }
      refreshJoinTokens();
    })
    .catch((err) => {
      console.error("Generate join link failed:", err);
      if (btn) {
        btn.textContent = "Generate";
        btn.disabled = false;
      }
    });
}

function copyJoinCommand(): void {
  const text = document.getElementById("join-command-text")?.textContent;
  if (text && navigator.clipboard) {
    navigator.clipboard.writeText(text).then(() => {
      const btn = document.getElementById("join-copy-btn");
      if (btn) {
        btn.textContent = "Copied!";
        setTimeout(() => {
          btn.textContent = "Copy";
        }, 2000);
      }
    });
  }
}

function getVal(id: string): string {
  return (document.getElementById(id) as HTMLInputElement)?.value || "";
}

function setVal(id: string, value: string): void {
  const el = document.getElementById(id) as HTMLInputElement;
  if (el) el.value = value;
}

function refreshMachines(): void {
  if (isViewActive("machines")) {
    api.fetchMachines().then((data) => {
      const machines = Array.isArray(data)
        ? data
        : ((data as any).machines ?? []);
      store.set("machinesCache", machines);
    });
    api
      .fetchJoinTokens()
      .then(({ tokens }) => store.set("joinTokensCache", tokens));
  }
}

function refreshJoinTokens(): void {
  api
    .fetchJoinTokens()
    .then(({ tokens }) => store.set("joinTokensCache", tokens))
    .catch(() => {});
}

// Notification settings (opened from the account menu)
export function setupNotificationsModal(): void {
  document.getElementById("open-notifications")?.addEventListener("click", () => {
    openDialog("notifications-modal");
    loadWebhookList();
  });
  bindClick("notif-add-webhook", addWebhook);
  const testBtn = document.getElementById("notif-test-btn");
  testBtn?.addEventListener("click", () => {
    testBtn.textContent = "Sending\u2026";
    const reset = (text: string) => {
      testBtn.textContent = text;
      setTimeout(() => (testBtn.textContent = "Send test"), 2000);
    };
    api.testNotification().then(() => reset("Sent")).catch(() => reset("Failed"));
  });
}

function checked(id: string): boolean {
  return (document.getElementById(id) as HTMLInputElement | null)?.checked === true;
}

function addWebhook(): void {
  const url = getVal("notif-webhook-url").trim();
  if (!url) return;
  const events: string[] = [];
  if (checked("notif-evt-all")) events.push("all");
  else {
    if (checked("notif-evt-completed")) events.push("pipeline.completed");
    if (checked("notif-evt-failed")) events.push("pipeline.failed");
    if (checked("notif-evt-alert")) events.push("alert");
  }
  api
    .addWebhook(url, getVal("notif-webhook-label").trim() || undefined, events.length ? events : undefined)
    .then(() => {
      setVal("notif-webhook-url", "");
      setVal("notif-webhook-label", "");
      loadWebhookList();
    })
    .catch((err) => toast("Could not add the webhook: " + String(err), "error"));
}

function loadWebhookList(): void {
  const container = document.getElementById("notif-webhook-list");
  if (!container) return;
  const note = (text: string) => container.replaceChildren(h("p", { class: "state-body", text }));
  note("Loading\u2026");
  api
    .fetchNotificationConfig()
    .then((config) => {
      if (!config.webhooks || config.webhooks.length === 0) return note("No webhooks configured.");
      container.replaceChildren(
        ...config.webhooks.map((w) =>
          h("div", { class: "webhook-item" },
            h("span", { class: "webhook-label", text: w.label }),
            h("span", { class: "webhook-url", text: w.url.length > 50 ? w.url.slice(0, 50) + "\u2026" : w.url }),
            h("span", { class: "webhook-events", text: w.events.join(", ") }),
            h("button", {
              type: "button",
              class: "btn sm danger",
              text: "Remove",
              "aria-label": "Remove webhook " + w.label,
              onclick: () => void removeWebhook(w.label, w.url),
            }),
          ),
        ),
      );
    })
    .catch(() => note("Could not load the notification config."));
}

async function removeWebhook(label: string, url: string): Promise<void> {
  const ok = await confirmDialog({
    title: `Remove the ${label || "unnamed"} webhook?`,
    body: `${url} stops receiving notifications. You can add it again later.`,
    confirmLabel: "Remove webhook",
    danger: true,
  });
  if (!ok) return;
  api
    .removeWebhook(url)
    .then(loadWebhookList)
    .catch((err) => toast("Could not remove the webhook: " + String(err), "error"));
}
