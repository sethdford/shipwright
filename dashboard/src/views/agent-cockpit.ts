// Agent Cockpit - full-screen agent view with live terminal, CPU/memory sparklines, self-healing ring

import { store } from "../core/state";
import { escapeHtml, formatDuration, fmtNum } from "../core/helpers";
import { icon } from "../design/icons";
import { colors } from "../design/tokens";
import { renderSparkline } from "../components/charts/sparkline";
import { renderSVGDonut } from "../components/charts/donut";
import { LiveTerminal } from "../components/terminal";
import { SSEClient } from "../core/sse";
import * as api from "../core/api";
import type { FleetState, View, PipelineInfo } from "../types/api";

let terminal: LiveTerminal | null = null;
let sseClient: SSEClient | null = null;
let selectedAgent: number | null = null;
let cpuHistory: number[] = [];
let memHistory: number[] = [];

function renderCockpit(data: FleetState): void {
  const container = document.getElementById("panel-agent-cockpit");
  if (!container) return;

  const pipelines = data.pipelines || [];
  if (pipelines.length === 0 && !selectedAgent) {
    container.innerHTML = `<div class="empty-state">${icon("cpu", 48)}<p>No active agents</p></div>`;
    return;
  }

  // Agent selector bar
  let html = '<div class="cockpit-layout">';
  html += '<div class="cockpit-agent-bar">';
  for (const p of pipelines) {
    const isSelected = selectedAgent === p.issue;
    const statusDot = p.status === "failed" ? "offline" : "online";
    html +=
      `<button class="cockpit-agent-btn${isSelected ? " selected" : ""}" data-issue="${p.issue}">` +
      `<span class="presence-dot ${statusDot}"></span>#${p.issue}</button>`;
  }
  html += "</div>";

  if (selectedAgent) {
    const pipeline = pipelines.find((p) => p.issue === selectedAgent);
    if (pipeline) {
      html += '<div class="cockpit-main">';

      // Top metrics row
      html += '<div class="cockpit-metrics">';

      // CPU sparkline
      html += '<div class="cockpit-metric-card">';
      html += `<div class="cockpit-metric-header">${icon("cpu", 16)} CPU</div>`;
      html += `<div class="cockpit-metric-chart">${cpuHistory.length > 1 ? renderSparkline(cpuHistory, colors.accent.cyan, 160, 40) : '<span class="text-muted">\u2014</span>'}</div>`;
      html += "</div>";

      // Memory sparkline
      html += '<div class="cockpit-metric-card">';
      html += `<div class="cockpit-metric-header">${icon("memory-stick", 16)} Memory</div>`;
      html += `<div class="cockpit-metric-chart">${memHistory.length > 1 ? renderSparkline(memHistory, colors.accent.purple, 160, 40) : '<span class="text-muted">\u2014</span>'}</div>`;
      html += "</div>";

      // Self-healing ring
      const healthPct =
        pipeline.status === "failed"
          ? 0
          : Math.min(
              100,
              ((pipeline.iteration || 0) / (pipeline.maxIterations || 20)) *
                100,
            );
      html += '<div class="cockpit-metric-card">';
      html += `<div class="cockpit-metric-header">${icon("shield-alert", 16)} Health</div>`;
      html += `<div class="cockpit-metric-chart">${renderSVGDonut(100 - healthPct)}</div>`;
      html += "</div>";

      // Stage + status
      html += '<div class="cockpit-metric-card">';
      html += `<div class="cockpit-metric-header">${icon("activity", 16)} Status</div>`;
      html += '<div class="cockpit-status-info">';
      html += `<div>Stage: <strong>${escapeHtml(pipeline.stage)}</strong></div>`;
      html += `<div>Iteration: ${pipeline.iteration || 0}/${pipeline.maxIterations || 20}</div>`;
      html += `<div>Elapsed: ${formatDuration(pipeline.elapsed_s)}</div>`;
      if (pipeline.linesWritten != null)
        html += `<div>Lines: ${fmtNum(pipeline.linesWritten)}</div>`;
      html += "</div></div>";

      html += "</div>"; // cockpit-metrics

      // Live Changes panel
      html += '<div class="cockpit-changes" id="cockpit-changes">';
      html += `<div class="cockpit-changes-header">${icon("file-diff", 16)} Files Changed <button class="btn-sm" id="cockpit-refresh-diff">Refresh</button></div>`;
      html +=
        '<div class="cockpit-changes-body" id="cockpit-changes-body"></div>';
      html += "</div>";

      // Live terminal
      html +=
        '<div class="cockpit-terminal" id="cockpit-terminal-container"></div>';

      html += "</div>"; // cockpit-main
    } else {
      html += `<div class="empty-state"><p>Agent #${selectedAgent} no longer active</p></div>`;
    }
  } else {
    html += `<div class="empty-state">${icon("terminal", 32)}<p>Select an agent to monitor</p></div>`;
  }

  html += "</div>";
  container.innerHTML = html;

  // Wire up agent selector
  container.querySelectorAll(".cockpit-agent-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const issue = parseInt(btn.getAttribute("data-issue") || "0", 10);
      if (issue) selectAgent(issue, data);
    });
  });

  // Initialize terminal
  if (selectedAgent) {
    const termContainer = document.getElementById("cockpit-terminal-container");
    if (termContainer) {
      terminal = new LiveTerminal(termContainer);
      connectAgentStream(selectedAgent);
    }

    // Load live changes
    loadCockpitChanges(selectedAgent);
    const refreshBtn = document.getElementById("cockpit-refresh-diff");
    if (refreshBtn) {
      refreshBtn.addEventListener("click", () => {
        if (selectedAgent) loadCockpitChanges(selectedAgent);
      });
    }

    // Update resource histories from agent heartbeat data
    const agents = data.agents || [];
    const agentInfo = agents.find((a) => a.issue === selectedAgent);
    if (agentInfo) {
      if (agentInfo.cpu_pct != null) {
        cpuHistory.push(agentInfo.cpu_pct);
        if (cpuHistory.length > 60) cpuHistory.shift();
      }
      if (agentInfo.memory_mb != null) {
        memHistory.push(agentInfo.memory_mb);
        if (memHistory.length > 60) memHistory.shift();
      }
    }
  }
}

function selectAgent(issue: number, data: FleetState): void {
  if (sseClient) sseClient.close();
  if (terminal) terminal.destroy();
  selectedAgent = issue;
  cpuHistory = [];
  memHistory = [];
  renderCockpit(data);
}

function loadCockpitChanges(issue: number): void {
  const body = document.getElementById("cockpit-changes-body");
  if (!body) return;
  body.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';

  api
    .fetchPipelineFiles(issue)
    .then((data) => {
      const files = data.files || [];
      if (files.length === 0) {
        body.innerHTML = '<div class="empty-state"><p>No changes yet</p></div>';
        return;
      }
      let html = "";
      for (const f of files) {
        const statusCls =
          f.status === "added"
            ? "file-added"
            : f.status === "deleted"
              ? "file-deleted"
              : "file-modified";
        const statusChar =
          f.status === "added" ? "A" : f.status === "deleted" ? "D" : "M";
        html += `<div class="changes-file-item ${statusCls}"><span class="file-status">${statusChar}</span><span class="file-path">${escapeHtml(f.path)}</span></div>`;
      }
      body.innerHTML = html;
    })
    .catch(() => {
      body.innerHTML =
        '<div class="empty-state"><p>Could not load changes</p></div>';
    });
}

function connectAgentStream(issue: number): void {
  if (sseClient) sseClient.close();

  sseClient = new SSEClient(
    `/api/logs/${issue}/stream`,
    (data) => {
      if (terminal) terminal.append(data);
    },
    () => {
      api
        .fetchLogs(issue)
        .then((data) => {
          if (terminal) terminal.append(data.content || "No logs available");
        })
        .catch(() => {
          if (terminal) terminal.append("Failed to load logs");
        });
    },
  );
  sseClient.connect();
}

export const agentCockpitView: View = {
  init() {},

  render(data: FleetState) {
    renderCockpit(data);
  },

  destroy() {
    if (sseClient) {
      sseClient.close();
      sseClient = null;
    }
    if (terminal) {
      terminal.destroy();
      terminal = null;
    }
    selectedAgent = null;
    cpuHistory = [];
    memHistory = [];
  },
};
