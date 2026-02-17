// Header bar + connection status + user menu + cost ticker

import { store } from "../core/state";
import { escapeHtml, fmtNum } from "../core/helpers";
import * as api from "../core/api";
import type { FleetState, DaemonConfig } from "../types/api";

let soundEnabled = false;
let previousPipelineIds: Set<number> = new Set();

export function setupHeader(): void {
  fetchUser();
  setupUserMenu();
  setupDaemonControlBar();
  setupEmergencyBrake();
  setupSoundToggle();
  setupThemeToggle();
  setupAmbientIndicator();
  setupNotificationsModal();
  fetchDaemonConfig();
  setInterval(fetchDaemonConfig, 30000);
}

function setupSoundToggle(): void {
  const headerActions = document.querySelector(".header-actions");
  if (!headerActions) return;

  const btn = document.createElement("button");
  btn.className = "sound-toggle";
  btn.id = "sound-toggle";
  btn.innerHTML = "\u{1F50A} Sound";
  btn.addEventListener("click", () => {
    soundEnabled = !soundEnabled;
    btn.classList.toggle("active", soundEnabled);
    btn.innerHTML = soundEnabled ? "\u{1F50A} Sound" : "\u{1F507} Mute";
  });

  // Insert before user avatar if possible
  const userAvatar = document.getElementById("user-avatar");
  if (userAvatar) {
    headerActions.insertBefore(btn, userAvatar);
  } else {
    headerActions.appendChild(btn);
  }
}

function setupThemeToggle(): void {
  const headerActions = document.querySelector(".header-actions");
  if (!headerActions) return;

  const saved = localStorage.getItem("sw-theme");
  if (saved === "light")
    document.documentElement.setAttribute("data-theme", "light");

  const btn = document.createElement("button");
  btn.className = "theme-toggle";
  btn.id = "theme-toggle";
  const isDark = () =>
    document.documentElement.getAttribute("data-theme") !== "light";
  btn.innerHTML = isDark() ? "\u263E Dark" : "\u2600 Light";
  btn.addEventListener("click", () => {
    if (isDark()) {
      document.documentElement.setAttribute("data-theme", "light");
      localStorage.setItem("sw-theme", "light");
      btn.innerHTML = "\u2600 Light";
    } else {
      document.documentElement.removeAttribute("data-theme");
      localStorage.setItem("sw-theme", "dark");
      btn.innerHTML = "\u263E Dark";
    }
  });

  const soundBtn = document.getElementById("sound-toggle");
  if (soundBtn) {
    headerActions.insertBefore(btn, soundBtn);
  } else {
    const userAvatar = document.getElementById("user-avatar");
    if (userAvatar) headerActions.insertBefore(btn, userAvatar);
    else headerActions.appendChild(btn);
  }
}

function setupAmbientIndicator(): void {
  const indicator = document.createElement("div");
  indicator.className = "ambient-indicator";
  indicator.id = "ambient-indicator";
  document.body.appendChild(indicator);
}

export function updateAmbientIndicator(data: FleetState): void {
  const indicator = document.getElementById("ambient-indicator");
  if (!indicator) return;

  const active = data.pipelines?.length || 0;
  const queue = data.queue?.length || 0;
  const anyFailed = data.pipelines?.some((p) => p.status === "failed");

  if (anyFailed) {
    indicator.className = "ambient-indicator critical";
  } else if (active > 0) {
    indicator.className =
      active > 3 ? "ambient-indicator busy" : "ambient-indicator";
  } else {
    indicator.style.display = "none";
    return;
  }
  indicator.style.display = "";
}

export function detectCompletions(data: FleetState): void {
  const currentIds = new Set(data.pipelines?.map((p) => p.issue) || []);

  // Check for pipelines that disappeared (completed or failed)
  for (const prevId of previousPipelineIds) {
    if (!currentIds.has(prevId)) {
      // Pipeline completed or failed - trigger visual effect
      const completedEvent = data.events?.find(
        (e) => e.issue === prevId && String(e.type || "").includes("completed"),
      );
      const failedEvent = data.events?.find(
        (e) => e.issue === prevId && String(e.type || "").includes("failed"),
      );

      if (completedEvent && soundEnabled) {
        playCompletionSound();
      } else if (failedEvent && soundEnabled) {
        playFailureSound();
      }
    }
  }

  previousPipelineIds = currentIds;
}

function playCompletionSound(): void {
  try {
    const audioCtx = new AudioContext();
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.connect(gain);
    gain.connect(audioCtx.destination);
    osc.frequency.setValueAtTime(523.25, audioCtx.currentTime); // C5
    osc.frequency.setValueAtTime(659.25, audioCtx.currentTime + 0.1); // E5
    osc.frequency.setValueAtTime(783.99, audioCtx.currentTime + 0.2); // G5
    gain.gain.setValueAtTime(0.1, audioCtx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + 0.5);
    osc.start(audioCtx.currentTime);
    osc.stop(audioCtx.currentTime + 0.5);
  } catch {}
}

function playFailureSound(): void {
  try {
    const audioCtx = new AudioContext();
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.connect(gain);
    gain.connect(audioCtx.destination);
    osc.type = "sawtooth";
    osc.frequency.setValueAtTime(200, audioCtx.currentTime);
    osc.frequency.setValueAtTime(150, audioCtx.currentTime + 0.2);
    gain.gain.setValueAtTime(0.08, audioCtx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + 0.4);
    osc.start(audioCtx.currentTime);
    osc.stop(audioCtx.currentTime + 0.4);
  } catch {}
}

function applyRoleRestrictions(role: string): void {
  if (role === "viewer") {
    // Hide all action buttons for viewers
    const selectors = [
      "#emergency-brake",
      "#daemon-btn-start",
      "#daemon-btn-stop",
      "#daemon-btn-pause",
      "#daemon-btn-patrol",
      "#btn-add-machine",
      "#btn-join-link",
      "#btn-create-invite",
      ".pipeline-checkbox",
      ".bulk-actions",
    ];
    for (const sel of selectors) {
      document.querySelectorAll(sel).forEach((el) => {
        (el as HTMLElement).style.display = "none";
      });
    }
  }
}

function fetchUser(): void {
  api
    .fetchMe()
    .then((user) => {
      store.set("currentUser", user);
      const avatarBtn = document.getElementById("user-avatar");
      const usernameEl = document.getElementById("dropdown-username");
      const initialsEl = document.getElementById("avatar-initials");
      const roleText = user.role ? ` (${user.role})` : "";
      if (usernameEl)
        usernameEl.textContent = escapeHtml(
          (user.username || "User") + roleText,
        );
      if (user.role) applyRoleRestrictions(user.role);

      if (user.avatarUrl && avatarBtn) {
        const img = document.createElement("img");
        img.src = user.avatarUrl;
        img.alt = escapeHtml(user.username || "User");
        avatarBtn.innerHTML = "";
        avatarBtn.appendChild(img);
      } else if (initialsEl) {
        const name = user.username || "?";
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
  if (el24 && cost.today_spent != null) {
    el24.textContent = "$" + cost.today_spent.toFixed(2);
  }
  if (elBudget && cost.daily_budget != null) {
    const remaining = Math.max(0, cost.daily_budget - cost.today_spent);
    elBudget.textContent = "$" + remaining.toFixed(2) + " remaining";
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
      if (issue) {
        import("../core/router").then(({ switchTab }) => {
          switchTab("pipelines");
        });
      }
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
    if (modal) {
      const fleetState = store.get("fleetState");
      const activeCount = document.getElementById("emergency-active-count");
      const queueCount = document.getElementById("emergency-queue-count");
      if (activeCount)
        activeCount.textContent = String(fleetState?.pipelines?.length || 0);
      if (queueCount)
        queueCount.textContent = String(fleetState?.queue?.length || 0);
      modal.style.display = "";
    }
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
  const startBtn = document.getElementById("daemon-btn-start");
  const stopBtn = document.getElementById("daemon-btn-stop");
  const pauseBtn = document.getElementById("daemon-btn-pause");
  const patrolBtn = document.getElementById("daemon-btn-patrol");

  if (startBtn) {
    startBtn.addEventListener("click", () => daemonControlAction("start"));
  }
  if (stopBtn) {
    stopBtn.addEventListener("click", () => daemonControlAction("stop"));
  }
  if (pauseBtn) {
    pauseBtn.addEventListener("click", () => {
      const badge = document.getElementById("daemon-status-badge");
      const action = badge?.classList.contains("paused") ? "resume" : "pause";
      daemonControlAction(action);
    });
  }
  if (patrolBtn) {
    patrolBtn.addEventListener("click", () => daemonControlAction("patrol"));
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

function setupNotificationsModal(): void {
  const openBtn = document.getElementById("open-notifications");
  const modal = document.getElementById("notifications-modal");
  const closeBtn = document.getElementById("notif-modal-close");
  const addBtn = document.getElementById("notif-add-webhook");
  const testBtn = document.getElementById("notif-test-btn");

  if (openBtn && modal) {
    openBtn.addEventListener("click", () => {
      modal.style.display = "";
      loadWebhookList();
    });
  }
  if (closeBtn && modal) {
    closeBtn.addEventListener("click", () => {
      modal.style.display = "none";
    });
  }
  if (modal) {
    modal.addEventListener("click", (e) => {
      if (e.target === modal) modal.style.display = "none";
    });
  }

  if (addBtn) {
    addBtn.addEventListener("click", () => {
      const urlInput = document.getElementById(
        "notif-webhook-url",
      ) as HTMLInputElement;
      const labelInput = document.getElementById(
        "notif-webhook-label",
      ) as HTMLInputElement;
      const allEvt = (
        document.getElementById("notif-evt-all") as HTMLInputElement
      )?.checked;
      const url = urlInput?.value.trim();
      if (!url) return;
      const events: string[] = [];
      if (allEvt) {
        events.push("all");
      } else {
        if (
          (document.getElementById("notif-evt-completed") as HTMLInputElement)
            ?.checked
        )
          events.push("pipeline.completed");
        if (
          (document.getElementById("notif-evt-failed") as HTMLInputElement)
            ?.checked
        )
          events.push("pipeline.failed");
        if (
          (document.getElementById("notif-evt-alert") as HTMLInputElement)
            ?.checked
        )
          events.push("alert");
      }
      api
        .addWebhook(
          url,
          labelInput?.value.trim() || undefined,
          events.length ? events : undefined,
        )
        .then(() => {
          if (urlInput) urlInput.value = "";
          if (labelInput) labelInput.value = "";
          loadWebhookList();
        });
    });
  }

  if (testBtn) {
    testBtn.addEventListener("click", () => {
      testBtn.textContent = "Sending...";
      api
        .testNotification()
        .then(() => {
          testBtn.textContent = "Sent!";
          setTimeout(() => {
            testBtn.textContent = "Send Test";
          }, 2000);
        })
        .catch(() => {
          testBtn.textContent = "Failed";
          setTimeout(() => {
            testBtn.textContent = "Send Test";
          }, 2000);
        });
    });
  }
}

function loadWebhookList(): void {
  const container = document.getElementById("notif-webhook-list");
  if (!container) return;
  container.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';

  api
    .fetchNotificationConfig()
    .then((config) => {
      if (!config.webhooks || config.webhooks.length === 0) {
        container.innerHTML =
          '<div class="empty-state"><p>No webhooks configured</p></div>';
        return;
      }
      let html = "";
      for (const w of config.webhooks) {
        html +=
          `<div class="webhook-item">` +
          `<span class="webhook-label">${escapeHtml(w.label)}</span>` +
          `<span class="webhook-url">${escapeHtml(w.url.substring(0, 50))}${w.url.length > 50 ? "..." : ""}</span>` +
          `<span class="webhook-events">${w.events.join(", ")}</span>` +
          `<button class="btn-sm btn-danger" data-webhook-url="${escapeHtml(w.url)}">Remove</button>` +
          "</div>";
      }
      container.innerHTML = html;
      container.querySelectorAll("[data-webhook-url]").forEach((btn) => {
        btn.addEventListener("click", () => {
          const url = btn.getAttribute("data-webhook-url") || "";
          api.removeWebhook(url).then(() => loadWebhookList());
        });
      });
    })
    .catch(() => {
      container.innerHTML =
        '<div class="empty-state"><p>Could not load config</p></div>';
    });
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
    const cfg = data.config as Record<string, unknown>;
    if (workersEl) workersEl.textContent = String(cfg.max_workers || "-");
    if (pollEl) pollEl.textContent = String(cfg.poll_interval || "-");
    if (patrolEl) {
      const patrol = cfg.patrol as Record<string, unknown> | undefined;
      patrolEl.textContent = String(patrol?.interval || "-");
    }
  }

  if (data.budget && budgetEl) {
    const budget = data.budget as Record<string, unknown>;
    const remaining = budget.remaining ?? budget.daily_limit ?? "-";
    budgetEl.textContent =
      typeof remaining === "number" ? remaining.toFixed(2) : String(remaining);
  }
}
