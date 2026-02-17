// Agents tab - agent cards grid with intervention controls

import { escapeHtml, formatDuration } from "../core/helpers";
import { icon } from "../design/icons";
import { openInterventionModal, confirmAbort } from "../components/modal";
import * as api from "../core/api";
import type { FleetState, View, PipelineInfo } from "../types/api";

function renderAgentsTab(data: FleetState): void {
  const container = document.getElementById("agents-grid");
  if (!container) return;

  const pipelines = data.pipelines || [];
  if (pipelines.length === 0) {
    container.innerHTML = `<div class="empty-state">${icon("users", 32)}<p>No active agents</p></div>`;
    return;
  }

  let html = "";
  for (const p of pipelines) {
    const statusClass = p.status === "failed" ? "agent-failed" : "agent-active";
    html +=
      `<div class="agent-card ${statusClass}">` +
      `<div class="agent-card-header">` +
      `<span class="agent-issue">#${p.issue}</span>` +
      `<span class="agent-title">${escapeHtml(p.title)}</span></div>` +
      `<div class="agent-card-body">` +
      `<div class="agent-info-row"><span class="agent-info-label">${icon("activity", 14)} Stage</span>` +
      `<span class="agent-info-value">${escapeHtml(p.stage)}</span></div>` +
      `<div class="agent-info-row"><span class="agent-info-label">${icon("timer", 14)} Elapsed</span>` +
      `<span class="agent-info-value">${formatDuration(p.elapsed_s)}</span></div>` +
      `<div class="agent-info-row"><span class="agent-info-label">${icon("refresh-cw", 14)} Iteration</span>` +
      `<span class="agent-info-value">${p.iteration || 0}/${p.maxIterations || 20}</span></div>` +
      `</div>` +
      `<div class="agent-card-actions">` +
      `<button class="agent-action-btn" data-action="message" data-issue="${p.issue}">${icon("message-square", 14)} Message</button>` +
      `<button class="agent-action-btn" data-action="pause" data-issue="${p.issue}">${icon("pause", 14)} Pause</button>` +
      `<button class="agent-action-btn danger" data-action="abort" data-issue="${p.issue}">${icon("square", 14)} Abort</button>` +
      `</div></div>`;
  }
  container.innerHTML = html;

  // Wire up action buttons
  container.querySelectorAll(".agent-action-btn").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const action = btn.getAttribute("data-action");
      const issue = parseInt(btn.getAttribute("data-issue") || "0", 10);
      if (!issue) return;

      switch (action) {
        case "message":
          openInterventionModal(issue);
          break;
        case "pause":
          api.sendIntervention(issue, "pause");
          break;
        case "abort":
          confirmAbort(issue);
          break;
      }
    });
  });
}

export const agentsView: View = {
  init() {},
  render(data: FleetState) {
    renderAgentsTab(data);
  },
  destroy() {},
};
