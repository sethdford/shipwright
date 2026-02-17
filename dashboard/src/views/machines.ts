// Machines tab - machine grid, health checks, worker management

import { store } from "../core/state";
import { escapeHtml } from "../core/helpers";
import { icon } from "../design/icons";
import {
  setupMachinesModals,
  updateWorkerCount,
  machineHealthCheckAction,
  confirmMachineRemove,
} from "../components/modal";
import * as api from "../core/api";
import type { FleetState, View, MachineInfo, JoinToken } from "../types/api";

function fetchMachinesTab(): void {
  api
    .fetchMachines()
    .then((machines) => {
      store.set("machinesCache", machines);
      renderMachinesTab(machines);
    })
    .catch(() => {});

  api
    .fetchJoinTokens()
    .then(({ tokens }) => {
      store.set("joinTokensCache", tokens);
      renderJoinTokens(tokens);
    })
    .catch(() => {});
}

function renderMachinesTab(machines: MachineInfo[]): void {
  const summaryEl = document.getElementById("machines-summary");
  const gridEl = document.getElementById("machines-grid");
  if (!summaryEl || !gridEl) return;

  summaryEl.innerHTML = renderMachineSummary(machines);

  if (machines.length === 0) {
    gridEl.innerHTML = `<div class="empty-state">${icon("server", 32)}<p>No machines registered</p></div>`;
    return;
  }

  gridEl.innerHTML = machines.map((m) => renderMachineCard(m)).join("");

  // Wire up action buttons
  gridEl.querySelectorAll(".machine-action-btn").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const action = btn.getAttribute("data-machine-action");
      const name = btn.getAttribute("data-machine-name") || "";
      if (action === "check") machineHealthCheckAction(name);
      else if (action === "remove") confirmMachineRemove(name);
    });
  });

  // Wire up worker sliders
  gridEl.querySelectorAll(".workers-slider").forEach((slider) => {
    slider.addEventListener("input", (e) => {
      const el = e.target as HTMLInputElement;
      const name = el.getAttribute("data-machine-name") || "";
      updateWorkerCount(name, el.value);
    });
  });
}

function renderMachineSummary(machines: MachineInfo[]): string {
  let totalMaxWorkers = 0;
  let totalActiveWorkers = 0;
  let onlineCount = 0;
  for (const m of machines) {
    totalMaxWorkers += m.max_workers || 0;
    totalActiveWorkers += m.active_workers || 0;
    if (m.status === "online") onlineCount++;
  }

  return (
    `<div class="machines-summary-card"><div class="stat-value">${machines.length}</div><div class="stat-label">Total Machines</div></div>` +
    `<div class="machines-summary-card"><div class="stat-value">${onlineCount}</div><div class="stat-label">Online</div></div>` +
    `<div class="machines-summary-card"><div class="stat-value">${totalActiveWorkers} / ${totalMaxWorkers}</div><div class="stat-label">Active / Max Workers</div></div>`
  );
}

function renderMachineCard(machine: MachineInfo): string {
  const name = machine.name || "";
  const host = machine.host || "\u2014";
  const role = machine.role || "worker";
  const status = machine.status || "offline";
  const maxWorkers = machine.max_workers || 4;
  const activeWorkers = machine.active_workers || 0;
  const health = machine.health || {};
  const daemonRunning = health.daemon_running || false;
  const heartbeatCount = health.heartbeat_count || 0;
  const lastHbAge = health.last_heartbeat_s_ago;
  let lastHbText = "\u2014";
  if (typeof lastHbAge === "number" && lastHbAge < 9999) {
    if (lastHbAge < 60) lastHbText = lastHbAge + "s ago";
    else if (lastHbAge < 3600)
      lastHbText = Math.floor(lastHbAge / 60) + "m ago";
    else lastHbText = Math.floor(lastHbAge / 3600) + "h ago";
  }

  return (
    `<div class="machine-card" id="machine-card-${escapeHtml(name)}">` +
    `<div class="machine-card-header">` +
    `<span class="presence-dot ${status}"></span>` +
    `<span class="machine-name">${escapeHtml(name)}</span>` +
    `<span class="machine-role">${escapeHtml(role)}</span></div>` +
    `<div class="machine-host">${escapeHtml(host)}</div>` +
    `<div class="machine-workers-section">` +
    `<div class="machine-workers-label-row"><span>Workers</span><span class="workers-count">${activeWorkers} / ${maxWorkers}</span></div>` +
    `<input type="range" class="workers-slider" min="1" max="64" value="${maxWorkers}" data-machine-name="${escapeHtml(name)}" title="Max workers" /></div>` +
    `<div class="machine-health">` +
    `<div class="machine-health-row"><span class="health-label">Daemon</span>` +
    `<span class="health-status ${daemonRunning ? "running" : "stopped"}">${daemonRunning ? "Running" : "Stopped"}</span></div>` +
    `<div class="machine-health-row"><span class="health-label">Heartbeats</span><span class="health-value">${heartbeatCount}</span></div>` +
    `<div class="machine-health-row"><span class="health-label">Last heartbeat</span><span class="health-value">${lastHbText}</span></div></div>` +
    `<div class="machine-card-actions">` +
    `<button class="machine-action-btn" data-machine-action="check" data-machine-name="${escapeHtml(name)}">Check</button>` +
    `<button class="machine-action-btn danger" data-machine-action="remove" data-machine-name="${escapeHtml(name)}">Remove</button></div></div>`
  );
}

function renderJoinTokens(tokens: JoinToken[]): void {
  const section = document.getElementById("join-tokens-section");
  const list = document.getElementById("join-tokens-list");
  if (!section || !list) return;
  if (!tokens || tokens.length === 0) {
    section.style.display = "none";
    return;
  }
  section.style.display = "";

  let html = "";
  for (const t of tokens) {
    const label = t.label || "Unlabeled";
    const created = t.created_at
      ? new Date(t.created_at).toLocaleDateString()
      : "\u2014";
    const used = t.used ? "Claimed" : "Active";
    const usedClass = t.used ? "c-amber" : "c-green";
    html +=
      `<div class="join-token-row">` +
      `<span class="join-token-label">${escapeHtml(label)}</span>` +
      `<span class="join-token-created">${created}</span>` +
      `<span class="join-token-status ${usedClass}">${used}</span></div>`;
  }
  list.innerHTML = html;
}

export const machinesView: View = {
  init() {
    setupMachinesModals();
    fetchMachinesTab();
  },
  render(_data: FleetState) {
    const cache = store.get("machinesCache");
    if (cache) renderMachinesTab(cache);
  },
  destroy() {},
};
