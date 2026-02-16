// Header bar + connection status + user menu + cost ticker

import { store } from "../core/state";
import { escapeHtml, fmtNum } from "../core/helpers";
import * as api from "../core/api";
import type { FleetState, DaemonConfig } from "../types/api";

export function setupHeader(): void {
  fetchUser();
  setupUserMenu();
  setupDaemonControlBar();
  setupEmergencyBrake();
  fetchDaemonConfig();
  setInterval(fetchDaemonConfig, 30000);
}

function fetchUser(): void {
  api
    .fetchMe()
    .then((user) => {
      store.set("currentUser", user);
      const avatarBtn = document.getElementById("user-avatar");
      const usernameEl = document.getElementById("dropdown-username");
      const initialsEl = document.getElementById("avatar-initials");
      if (usernameEl)
        usernameEl.textContent = escapeHtml(
          user.name || user.username || "User",
        );

      if (user.avatar_url && avatarBtn) {
        const img = document.createElement("img");
        img.src = user.avatar_url;
        img.alt = escapeHtml(user.name || "User");
        avatarBtn.innerHTML = "";
        avatarBtn.appendChild(img);
      } else if (initialsEl) {
        const name = user.name || user.username || "?";
        const parts = name.split(" ");
        const initials =
          parts.length >= 2
            ? (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
            : name.substring(0, 2).toUpperCase();
        initialsEl.textContent = initials;
      }
    })
    .catch(() => {});
}

function setupUserMenu(): void {
  const avatar = document.getElementById("user-avatar");
  const dropdown = document.getElementById("user-dropdown");
  if (!avatar || !dropdown) return;

  avatar.addEventListener("click", (e) => {
    e.stopPropagation();
    dropdown.classList.toggle("open");
  });

  document.addEventListener("click", () => {
    dropdown.classList.remove("open");
  });
}

export function renderCostTicker(data: FleetState): void {
  const cost = data.cost;
  if (!cost) return;
  const el24 = document.getElementById("cost-24h");
  const elBudget = document.getElementById("cost-budget");
  if (el24 && cost.total_24h != null) {
    el24.textContent = "$" + cost.total_24h.toFixed(2);
  }
  if (elBudget && cost.budget_remaining != null) {
    elBudget.textContent =
      "$" + cost.budget_remaining.toFixed(2) + " remaining";
  }
}

export function renderAlertBanner(data: FleetState): void {
  const container = document.getElementById("alert-banner");
  if (!container) return;

  if (store.get("alertDismissed")) {
    container.innerHTML = "";
    container.style.display = "none";
    return;
  }

  api
    .fetchAlerts()
    .then(({ alerts }) => {
      if (!alerts || alerts.length === 0) {
        container.innerHTML = "";
        container.style.display = "none";
        return;
      }

      const alert = alerts[0];
      store.set("alertsCache", alerts);

      const severityClass = "alert-" + (alert.severity || "info");
      let html =
        `<div class="alert-banner-content ${severityClass}">` +
        `<span class="alert-banner-icon">\u26A0</span>` +
        `<span class="alert-banner-msg">${escapeHtml(alert.message || "")}</span>` +
        `<span class="alert-banner-actions">`;

      if (alert.issue) {
        html += `<button class="alert-action-btn" data-action="view-alert" data-issue="${alert.issue}">View</button>`;
      }
      if (alert.type === "failure_spike") {
        html += `<button class="alert-action-btn btn-abort" data-action="emergency-brake">Emergency Brake</button>`;
      }
      if (alert.type === "stuck_pipeline" && alert.issue) {
        html += `<button class="alert-action-btn btn-abort" data-action="abort-alert" data-issue="${alert.issue}">Abort</button>`;
        html += `<button class="alert-action-btn" data-action="skip-alert" data-issue="${alert.issue}">Skip Stage</button>`;
      }
      html += `<button class="alert-dismiss-btn" data-action="dismiss-alert">\u2715</button>`;
      html += "</span></div>";

      container.innerHTML = html;
      container.style.display = "";

      // Wire up alert action buttons
      container.querySelectorAll("[data-action]").forEach((btn) => {
        btn.addEventListener("click", handleAlertAction);
      });
    })
    .catch(() => {
      container.innerHTML = "";
      container.style.display = "none";
    });
}

function handleAlertAction(e: Event): void {
  const btn = e.currentTarget as HTMLElement;
  const action = btn.getAttribute("data-action");
  const issue = btn.getAttribute("data-issue");

  switch (action) {
    case "dismiss-alert":
      store.set("alertDismissed", true);
      const container = document.getElementById("alert-banner");
      if (container) {
        container.innerHTML = "";
        container.style.display = "none";
      }
      setTimeout(() => store.set("alertDismissed", false), 30000);
      break;
    case "emergency-brake":
      const modal = document.getElementById("emergency-modal");
      if (modal) modal.style.display = "";
      break;
    case "abort-alert":
      if (issue) api.sendIntervention(issue, "abort");
      break;
    case "skip-alert":
      if (issue) api.sendIntervention(issue, "skip_stage");
      break;
    case "view-alert":
      // Import switchTab dynamically to avoid circular deps
      import("./header").then(() => {
        const { switchTab } = require("../core/router");
        if (issue) {
          switchTab("pipelines");
        }
      });
      break;
  }
}

export function updateEmergencyBrakeVisibility(data: FleetState): void {
  const brakeBtn = document.getElementById("emergency-brake");
  if (!brakeBtn) return;
  const active = data.pipelines ? data.pipelines.length : 0;
  brakeBtn.style.display = active > 0 ? "" : "none";
}

function setupEmergencyBrake(): void {
  const brakeBtn = document.getElementById("emergency-brake");
  if (!brakeBtn) return;

  brakeBtn.addEventListener("click", () => {
    const modal = document.getElementById("emergency-modal");
    if (modal) modal.style.display = "";
  });

  const confirmBtn = document.getElementById("emergency-confirm");
  const cancelBtn = document.getElementById("emergency-cancel");
  const modal = document.getElementById("emergency-modal");

  if (cancelBtn && modal) {
    cancelBtn.addEventListener("click", () => {
      modal.style.display = "none";
    });
  }
  if (modal) {
    modal.addEventListener("click", (e) => {
      if (e.target === modal) modal.style.display = "none";
    });
  }
  if (confirmBtn) {
    confirmBtn.addEventListener("click", () => {
      api
        .emergencyBrake()
        .then(() => {
          if (modal) modal.style.display = "none";
        })
        .catch((err) => {
          console.error("Emergency brake failed:", err);
          if (modal) modal.style.display = "none";
        });
    });
  }
}

function fetchDaemonConfig(): void {
  api
    .fetchDaemonConfig()
    .then((data) => {
      store.set("daemonConfig", data);
      updateDaemonControlBar(data);
    })
    .catch(() => {});
}

function setupDaemonControlBar(): void {
  const pauseBtn = document.getElementById("daemon-btn-pause");
  if (pauseBtn) {
    pauseBtn.addEventListener("click", () => {
      const badge = document.getElementById("daemon-status-badge");
      const action = badge?.classList.contains("paused") ? "resume" : "pause";
      daemonControlAction(action);
    });
  }
}

async function daemonControlAction(action: string): Promise<void> {
  const btn = document.getElementById("daemon-btn-" + action);
  if (btn) (btn as HTMLButtonElement).disabled = true;
  try {
    await api.daemonControl(action);
    setTimeout(fetchDaemonConfig, 1000);
  } catch (err) {
    console.error("Daemon control failed:", err);
  } finally {
    if (btn) (btn as HTMLButtonElement).disabled = false;
  }
}

function updateDaemonControlBar(data: DaemonConfig): void {
  const badge = document.getElementById("daemon-status-badge");
  const pauseBtn = document.getElementById("daemon-btn-pause");
  const workersEl = document.getElementById("daemon-info-workers");
  const pollEl = document.getElementById("daemon-info-poll");
  const patrolEl = document.getElementById("daemon-info-patrol");
  const budgetEl = document.getElementById("daemon-info-budget");

  if (!badge) return;

  if (data.paused) {
    badge.textContent = "Paused";
    badge.className = "daemon-status-badge paused";
    if (pauseBtn) pauseBtn.textContent = "Resume";
  } else if (data.config?.watch_label) {
    badge.textContent = "Running";
    badge.className = "daemon-status-badge running";
    if (pauseBtn) pauseBtn.textContent = "Pause";
  } else {
    badge.textContent = "Stopped";
    badge.className = "daemon-status-badge stopped";
    if (pauseBtn) pauseBtn.textContent = "Pause";
  }

  if (data.config) {
    if (workersEl)
      workersEl.textContent = String(data.config.max_workers || "-");
    if (pollEl) pollEl.textContent = String(data.config.poll_interval || "-");
    if (patrolEl)
      patrolEl.textContent = String(data.config.patrol?.interval || "-");
  }

  if (data.budget && budgetEl) {
    const remaining = data.budget.remaining ?? data.budget.daily_limit ?? "-";
    budgetEl.textContent =
      typeof remaining === "number" ? remaining.toFixed(2) : String(remaining);
  }
}
