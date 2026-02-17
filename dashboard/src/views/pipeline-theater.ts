// Pipeline Theater - live terminal + animated stage rail + token burn meter + file accumulator

import { store } from "../core/state";
import { escapeHtml, formatDuration, fmtNum } from "../core/helpers";
import { icon } from "../design/icons";
import { colors, STAGES, STAGE_HEX, STAGE_SHORT } from "../design/tokens";
import { LiveTerminal } from "../components/terminal";
import { SSEClient } from "../core/sse";
import { renderPipelineSVG } from "../components/charts/pipeline-rail";
import * as api from "../core/api";
import type { FleetState, View, PipelineInfo } from "../types/api";

let terminal: LiveTerminal | null = null;
let sseClient: SSEClient | null = null;
let selectedIssue: number | null = null;

function renderTheater(data: FleetState): void {
  const container = document.getElementById("panel-pipeline-theater");
  if (!container) return;

  const pipelines = data.pipelines || [];
  if (pipelines.length === 0 && !selectedIssue) {
    container.innerHTML = `<div class="empty-state">${icon("eye", 48)}<p>No active pipelines to observe</p></div>`;
    return;
  }

  // Pipeline selector
  let html = '<div class="theater-layout">';
  html += '<div class="theater-sidebar">';
  html += '<div class="theater-sidebar-header">Active Pipelines</div>';
  for (const p of pipelines) {
    const isSelected = selectedIssue === p.issue;
    html +=
      `<div class="theater-pipeline-item${isSelected ? " selected" : ""}" data-issue="${p.issue}">` +
      `<span class="theater-issue">#${p.issue}</span>` +
      `<span class="theater-stage">${escapeHtml(p.stage)}</span>` +
      `<span class="theater-elapsed">${formatDuration(p.elapsed_s)}</span></div>`;
  }
  html += "</div>";

  // Main theater area
  html += '<div class="theater-main">';
  if (selectedIssue) {
    const pipeline = pipelines.find((p) => p.issue === selectedIssue);
    if (pipeline) {
      // Stage rail
      html += `<div class="theater-stage-rail">${renderPipelineSVG(pipeline)}</div>`;

      // Token burn + file accumulator
      html += '<div class="theater-metrics-bar">';
      html +=
        `<div class="theater-metric"><span class="theater-metric-label">${icon("zap", 14)} Iteration</span>` +
        `<span class="theater-metric-value">${pipeline.iteration || 0}/${pipeline.maxIterations || 20}</span></div>`;
      if (pipeline.linesWritten != null) {
        html +=
          `<div class="theater-metric"><span class="theater-metric-label">${icon("file-diff", 14)} Lines</span>` +
          `<span class="theater-metric-value">${fmtNum(pipeline.linesWritten)}</span></div>`;
      }
      if (pipeline.cost != null) {
        html +=
          `<div class="theater-metric"><span class="theater-metric-label">${icon("dollar-sign", 14)} Cost</span>` +
          `<span class="theater-metric-value">$${pipeline.cost.toFixed(2)}</span></div>`;
      }
      html += "</div>";

      // Live Changes panel (diff + files)
      html += '<div class="theater-changes" id="theater-changes">';
      html += `<div class="theater-changes-header">${icon("file-diff", 16)} Live Changes <button class="btn-sm" id="theater-refresh-diff">Refresh</button></div>`;
      html +=
        '<div class="theater-changes-body" id="theater-changes-body"><div class="empty-state"><p>Loading changes...</p></div></div>';
      html += "</div>";

      // Live terminal
      html +=
        '<div class="theater-terminal" id="theater-terminal-container"></div>';
    } else {
      html += `<div class="empty-state"><p>Pipeline #${selectedIssue} no longer active</p></div>`;
    }
  } else {
    html += `<div class="empty-state">${icon("terminal", 32)}<p>Select a pipeline to observe</p></div>`;
  }
  html += "</div></div>";
  container.innerHTML = html;

  // Wire up pipeline selection
  container.querySelectorAll(".theater-pipeline-item").forEach((item) => {
    item.addEventListener("click", () => {
      const issue = parseInt(item.getAttribute("data-issue") || "0", 10);
      if (issue) selectPipeline(issue, data);
    });
  });

  // Initialize terminal and live changes if pipeline is selected
  if (selectedIssue) {
    const termContainer = document.getElementById("theater-terminal-container");
    if (termContainer) {
      terminal = new LiveTerminal(termContainer);
      connectLogStream(selectedIssue);
    }
    loadLiveChanges(selectedIssue);
    const refreshBtn = document.getElementById("theater-refresh-diff");
    if (refreshBtn) {
      refreshBtn.addEventListener("click", () => {
        if (selectedIssue) loadLiveChanges(selectedIssue);
      });
    }
  }
}

function selectPipeline(issue: number, data: FleetState): void {
  if (sseClient) sseClient.close();
  if (terminal) terminal.destroy();
  selectedIssue = issue;
  renderTheater(data);
}

function loadLiveChanges(issue: number): void {
  const body = document.getElementById("theater-changes-body");
  if (!body) return;

  Promise.all([
    api.fetchPipelineFiles(issue).catch(() => ({ files: [] })),
    api.fetchPipelineDiff(issue).catch(() => ({
      diff: "",
      stats: { files_changed: 0, insertions: 0, deletions: 0 },
      worktree: "",
    })),
  ]).then(([filesData, diffData]) => {
    const files = filesData.files || [];
    const stats = diffData.stats;
    let html = "";

    // Stats summary
    if (stats.files_changed > 0) {
      html +=
        `<div class="changes-stats">` +
        `<span class="stat-files">${stats.files_changed} file${stats.files_changed !== 1 ? "s" : ""}</span>` +
        `<span class="stat-add">+${stats.insertions}</span>` +
        `<span class="stat-del">-${stats.deletions}</span></div>`;
    }

    // File list
    if (files.length > 0) {
      html += '<div class="changes-file-list">';
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
      html += "</div>";
    }

    // Diff preview (truncated)
    if (diffData.diff) {
      const truncatedDiff =
        diffData.diff.length > 5000
          ? diffData.diff.substring(0, 5000) + "\n... (truncated)"
          : diffData.diff;
      html += `<details class="changes-diff-details"><summary>Show Diff</summary><pre class="changes-diff">${escapeHtml(truncatedDiff)}</pre></details>`;
    }

    if (!html) {
      html =
        '<div class="empty-state"><p>No changes detected (worktree may not exist yet)</p></div>';
    }

    body.innerHTML = html;
  });
}

function connectLogStream(issue: number): void {
  if (sseClient) sseClient.close();

  // Try SSE endpoint first, fall back to static logs
  sseClient = new SSEClient(
    `/api/logs/${issue}/stream`,
    (data) => {
      if (terminal) terminal.append(data);
    },
    () => {
      // SSE not available, load static logs
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

export const pipelineTheaterView: View = {
  init() {},

  render(data: FleetState) {
    renderTheater(data);
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
    selectedIssue = null;
  },
};
