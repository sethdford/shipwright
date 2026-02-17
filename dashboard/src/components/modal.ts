// Modal system for intervention, machine management, and join links

import * as api from "../core/api";
import { store } from "../core/state";
import { escapeHtml } from "../core/helpers";

let interventionTarget: number | null = null;
let removeMachineTarget: string | null = null;
let workerUpdateTimer: ReturnType<typeof setTimeout> | null = null;

// Intervention Modal
export function setupInterventionModal(): void {
  const modal = document.getElementById("intervention-modal");
  const closeBtn = document.getElementById("modal-close");
  const cancelBtn = document.getElementById("modal-cancel");
  const sendBtn = document.getElementById("modal-send");
  const msgEl = document.getElementById(
    "modal-message",
  ) as HTMLTextAreaElement | null;

  function closeModal() {
    if (modal) modal.style.display = "none";
    interventionTarget = null;
  }

  if (closeBtn) closeBtn.addEventListener("click", closeModal);
  if (cancelBtn) cancelBtn.addEventListener("click", closeModal);
  if (modal)
    modal.addEventListener("click", (e) => {
      if (e.target === modal) closeModal();
    });

  if (sendBtn) {
    sendBtn.addEventListener("click", () => {
      if (interventionTarget && msgEl?.value.trim()) {
        api.sendIntervention(interventionTarget, "message", {
          message: msgEl.value.trim(),
        });
        closeModal();
      }
    });
  }
}

export function openInterventionModal(issue: number): void {
  interventionTarget = issue;
  const modal = document.getElementById("intervention-modal");
  const title = document.getElementById("modal-title");
  const msg = document.getElementById(
    "modal-message",
  ) as HTMLTextAreaElement | null;
  if (modal) modal.style.display = "";
  if (title) title.textContent = "Send Message to #" + issue;
  if (msg) msg.value = "";
}

export function confirmAbort(issue: number): void {
  if (
    confirm("Abort pipeline for issue #" + issue + "? This cannot be undone.")
  ) {
    api.sendIntervention(issue, "abort");
  }
}

// Bulk Actions
export function setupBulkActions(): void {
  const pauseBtn = document.getElementById("bulk-pause");
  const resumeBtn = document.getElementById("bulk-resume");
  const abortBtn = document.getElementById("bulk-abort");

  if (pauseBtn) {
    pauseBtn.addEventListener("click", () => {
      const issues = Object.keys(store.get("selectedIssues"));
      issues.forEach((i) => api.sendIntervention(i, "pause"));
    });
  }

  if (resumeBtn) {
    resumeBtn.addEventListener("click", () => {
      const issues = Object.keys(store.get("selectedIssues"));
      issues.forEach((i) => api.sendIntervention(i, "resume"));
    });
  }

  if (abortBtn) {
    abortBtn.addEventListener("click", () => {
      const issues = Object.keys(store.get("selectedIssues"));
      if (issues.length === 0) return;
      if (
        confirm(
          "Abort " + issues.length + " pipeline(s)? This cannot be undone.",
        )
      ) {
        issues.forEach((i) => api.sendIntervention(i, "abort"));
        store.set("selectedIssues", {});
        updateBulkToolbar();
      }
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

  // Add machine modal
  bindClick("machine-modal-close", closeAddMachineModal);
  bindClick("machine-modal-cancel", closeAddMachineModal);
  bindClick("machine-modal-submit", submitAddMachine);

  // Join link modal
  bindClick("join-modal-close", closeJoinLinkModal);
  bindClick("join-modal-cancel", closeJoinLinkModal);
  bindClick("join-modal-generate", generateJoinLink);
  bindClick("join-copy-btn", copyJoinCommand);

  // Remove machine modal
  bindClick("remove-modal-close", () => {
    const el = document.getElementById("remove-machine-modal");
    if (el) el.style.display = "none";
  });
  bindClick("remove-modal-cancel", () => {
    const el = document.getElementById("remove-machine-modal");
    if (el) el.style.display = "none";
  });
  bindClick("remove-modal-confirm", executeRemoveMachine);
}

function bindClick(id: string, handler: () => void): void {
  const el = document.getElementById(id);
  if (el) el.addEventListener("click", handler);
}

function openAddMachineModal(): void {
  const modal = document.getElementById("add-machine-modal");
  if (modal) modal.style.display = "flex";
  setVal("machine-name", "");
  setVal("machine-host", "");
  setVal("machine-ssh-user", "");
  setVal("machine-path", "");
  setVal("machine-workers", "4");
  setVal("machine-role", "worker");
  const err = document.getElementById("machine-modal-error");
  if (err) err.style.display = "none";
}

function closeAddMachineModal(): void {
  const modal = document.getElementById("add-machine-modal");
  if (modal) modal.style.display = "none";
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
  const cb = document.getElementById("remove-stop-daemon") as HTMLInputElement;
  if (cb) cb.checked = false;
  const modal = document.getElementById("remove-machine-modal");
  if (modal) modal.style.display = "flex";
}

function executeRemoveMachine(): void {
  if (!removeMachineTarget) return;
  api
    .removeMachine(removeMachineTarget)
    .then(() => {
      const modal = document.getElementById("remove-machine-modal");
      if (modal) modal.style.display = "none";
      removeMachineTarget = null;
      refreshMachines();
    })
    .catch((err) => {
      console.error("Remove machine failed:", err);
      const modal = document.getElementById("remove-machine-modal");
      if (modal) modal.style.display = "none";
      removeMachineTarget = null;
    });
}

function openJoinLinkModal(): void {
  const modal = document.getElementById("join-link-modal");
  if (modal) modal.style.display = "flex";
  setVal("join-label", "");
  setVal("join-workers", "4");
  const cmdDisplay = document.getElementById("join-command-display");
  if (cmdDisplay) cmdDisplay.style.display = "none";
  const cmdText = document.getElementById("join-command-text");
  if (cmdText) cmdText.textContent = "";
}

function closeJoinLinkModal(): void {
  const modal = document.getElementById("join-link-modal");
  if (modal) modal.style.display = "none";
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
  const tab = store.get("activeTab");
  if (tab === "machines") {
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
