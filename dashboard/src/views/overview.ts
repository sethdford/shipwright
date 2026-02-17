// Overview tab - stats, pipelines, queue, activity, resources, cost, machines

import { store } from "../core/state";
import {
  escapeHtml,
  fmtNum,
  formatDuration,
  formatTime,
  animateValue,
  getBadgeClass,
  getTypeShort,
} from "../core/helpers";
import { renderPipelineSVG } from "../components/charts/pipeline-rail";
import { renderCostTicker } from "../components/header";
import { switchTab } from "../core/router";
import * as api from "../core/api";
import { fetchPipelineDetail } from "./pipelines";
import { icon } from "../design/icons";
import type {
  FleetState,
  View,
  PipelineInfo,
  QueueItem,
  EventItem,
} from "../types/api";

function renderStats(data: FleetState): void {
  const d = data.daemon || ({} as any);
  const m = data.metrics || ({} as any);
  const firstRender = store.get("firstRender");

  const statusEl = document.getElementById("stat-status");
  const statusDot = document.getElementById("status-dot");
  if (statusEl && statusDot) {
    if (d.running) {
      statusEl.textContent = "OPERATIONAL";
      statusEl.className = "stat-value status-green";
      statusDot.className = "pulse-dot operational";
    } else {
      statusEl.textContent = "OFFLINE";
      statusEl.className = "stat-value status-rose";
      statusDot.className = "pulse-dot offline";
    }
  }

  const active = data.pipelines ? data.pipelines.length : 0;
  const max = d.maxParallel || 0;
  const activeEl = document.getElementById("stat-active");
  if (activeEl) {
    if (firstRender && active > 0) {
      animateValue(activeEl, 0, active, 600, " / " + fmtNum(max));
    } else {
      activeEl.textContent = fmtNum(active) + " / " + fmtNum(max);
    }
  }
  const barPct = max > 0 ? Math.min((active / max) * 100, 100) : 0;
  const bar = document.getElementById("stat-active-bar");
  if (bar) bar.style.width = barPct + "%";

  const queued = data.queue ? data.queue.length : 0;
  const queueEl = document.getElementById("stat-queue");
  if (queueEl) {
    queueEl.textContent = fmtNum(queued);
    queueEl.className =
      queued > 0 ? "stat-value status-amber" : "stat-value status-green";
  }
  const queueSub = document.getElementById("stat-queue-sub");
  if (queueSub)
    queueSub.textContent = queued === 1 ? "issue waiting" : "issues waiting";

  const completed = m.completed ?? 0;
  const completedEl = document.getElementById("stat-completed");
  if (completedEl) {
    if (firstRender && completed > 0) {
      animateValue(completedEl, 0, completed, 800, "");
    } else {
      completedEl.textContent = fmtNum(completed);
    }
  }
  const failed = m.failed ?? 0;
  const failedSub = document.getElementById("stat-failed-sub");
  if (failedSub) {
    failedSub.textContent = fmtNum(failed) + " failed";
    failedSub.className =
      failed > 0 ? "stat-subtitle failed-some" : "stat-subtitle failed-none";
  }
}

function renderOverviewPipelines(data: FleetState): void {
  const container = document.getElementById("active-pipelines");
  if (!container) return;
  const firstRender = store.get("firstRender");

  if (!data.pipelines || data.pipelines.length === 0) {
    container.innerHTML = `<div class="empty-state">${icon("clock", 32)}<p>No active pipelines</p></div>`;
    return;
  }

  let html = "";
  for (let idx = 0; idx < data.pipelines.length; idx++) {
    const p = data.pipelines[idx];
    const maxIter = p.maxIterations || 20;
    const curIter = p.iteration || 0;
    const iterPct = maxIter > 0 ? Math.min((curIter / maxIter) * 100, 100) : 0;

    const linesText =
      p.linesWritten != null ? fmtNum(p.linesWritten) + " lines" : "";
    const testsText =
      p.testsPassing === true
        ? '<span class="tests-pass">Tests \u2713</span>'
        : p.testsPassing === false
          ? '<span class="tests-fail">Tests \u2717</span>'
          : "";
    const metaParts = [linesText, testsText].filter(Boolean);
    const animDelay = firstRender
      ? ` style="animation-delay:${idx * 0.05}s"`
      : "";

    html +=
      `<div class="pipeline-card" data-issue="${p.issue}"${animDelay}>` +
      `<div class="pipeline-header">` +
      `<span class="pipeline-issue">#${p.issue}</span>` +
      `<span class="pipeline-title">${escapeHtml(p.title)}</span>` +
      `<span class="pipeline-elapsed">${formatDuration(p.elapsed_s)}</span></div>` +
      `<div class="pipeline-svg-wrap">${renderPipelineSVG(p)}</div>` +
      `<div class="pipeline-iter">` +
      `<span class="pipeline-iter-label">Iteration ${curIter}/${maxIter}</span>` +
      `<div class="iter-bar-track"><div class="iter-bar-fill" style="width:${iterPct}%"></div></div></div>` +
      `<div class="pipeline-meta">${metaParts.join(" <span>\u00b7</span> ")}</div>` +
      (p.worktree
        ? `<div class="pipeline-worktree">WORKTREE: ${escapeHtml(p.worktree)}</div>`
        : "") +
      `</div>`;
  }
  container.innerHTML = html;

  container.querySelectorAll(".pipeline-card").forEach((card) => {
    card.addEventListener("click", () => {
      const issue = card.getAttribute("data-issue");
      if (issue) {
        switchTab("pipelines");
        fetchPipelineDetail(Number(issue));
      }
    });
  });
}

function renderQueue(data: FleetState): void {
  const container = document.getElementById("queue-list");
  if (!container) return;

  if (!data.queue || data.queue.length === 0) {
    container.innerHTML = '<div class="empty-state"><p>Queue clear</p></div>';
    return;
  }

  let html = "";
  for (let i = 0; i < data.queue.length; i++) {
    const q = data.queue[i];
    const costEst =
      q.estimated_cost != null
        ? ` <span class="queue-cost-est">~$${q.estimated_cost.toFixed(2)}</span>`
        : "";
    html +=
      `<div class="queue-row" data-queue-idx="${i}" data-issue="${q.issue}">` +
      `<span class="queue-issue">#${q.issue}</span>` +
      `<span class="queue-title-text">${escapeHtml(q.title)}</span>` +
      `<span class="queue-score">${q.score != null ? q.score : "\u2014"}</span>${costEst}</div>`;
    html += `<div class="queue-scoring-detail" id="queue-detail-${i}" style="display:none">`;
    if (q.factors) {
      html += renderScoringFactors(
        q.factors as unknown as Record<string, unknown>,
      );
    }
    html += `<div class="queue-triage-reasoning" id="queue-reasoning-${i}"></div>`;
    html += `</div>`;
  }
  container.innerHTML = html;

  // Fetch detailed queue data for triage reasoning
  let detailedData: Array<Record<string, unknown>> | null = null;
  api
    .fetchQueueDetailed()
    .then((d) => {
      detailedData = d.items || [];
    })
    .catch(() => {});

  container.querySelectorAll(".queue-row").forEach((row) => {
    row.addEventListener("click", () => {
      const idx = row.getAttribute("data-queue-idx");
      const detail = document.getElementById("queue-detail-" + idx);
      if (!detail) return;
      const isHidden = detail.style.display === "none";
      detail.style.display = isHidden ? "" : "none";

      if (isHidden && detailedData) {
        const issue = row.getAttribute("data-issue");
        const reasoningEl = document.getElementById("queue-reasoning-" + idx);
        if (reasoningEl && !reasoningEl.innerHTML) {
          const match = detailedData.find((d) => String(d.issue) === issue);
          if (match) {
            let rHtml = "";
            if (match.triage_reason || match.reason)
              rHtml += `<div class="triage-reason"><strong>Triage:</strong> ${escapeHtml(String(match.triage_reason || match.reason))}</div>`;
            if (match.complexity_estimate)
              rHtml += `<div class="triage-detail"><strong>Complexity:</strong> ${escapeHtml(String(match.complexity_estimate))}</div>`;
            if (match.labels)
              rHtml += `<div class="triage-detail"><strong>Labels:</strong> ${escapeHtml(String(match.labels))}</div>`;
            if (match.age_hours)
              rHtml += `<div class="triage-detail"><strong>Age:</strong> ${Number(match.age_hours).toFixed(1)}h</div>`;
            reasoningEl.innerHTML = rHtml;
          }
        }
      }
    });
  });
}

function renderScoringFactors(factors: Record<string, unknown>): string {
  const keys = [
    "complexity",
    "impact",
    "priority",
    "age",
    "dependency",
    "memory",
  ];
  let html = '<div class="scoring-factors">';
  for (const k of keys) {
    const val = Number(factors[k] ?? 0);
    const pct = Math.max(0, Math.min(100, val));
    html +=
      `<div class="scoring-factor-row">` +
      `<span class="scoring-factor-label">${escapeHtml(k)}</span>` +
      `<div class="scoring-factor-track"><div class="scoring-factor-fill" style="width:${pct}%"></div></div>` +
      `<span class="scoring-factor-val">${pct}</span></div>`;
  }
  html += "</div>";
  return html;
}

function renderOverviewActivity(data: FleetState): void {
  const container = document.getElementById("activity-feed");
  if (!container) return;

  if (!data.events || data.events.length === 0) {
    container.innerHTML =
      '<div class="empty-state"><p>Awaiting events...</p></div>';
    return;
  }

  const events = data.events.slice(-10).reverse();
  let html = "";
  for (const ev of events) {
    const typeRaw = String(ev.type || "unknown");
    const typeShort = getTypeShort(typeRaw);
    const badgeClass = getBadgeClass(typeRaw);

    const skip: Record<string, boolean> = {
      ts: true,
      type: true,
      timestamp: true,
    };
    const dparts: string[] = [];
    for (const [key, val] of Object.entries(ev)) {
      if (!skip[key]) dparts.push(key + "=" + val);
    }
    const detail = dparts.join(" ");

    html +=
      `<div class="activity-row">` +
      `<span class="activity-ts">${formatTime(ev.ts || ev.timestamp)}</span>` +
      `<span class="activity-badge ${badgeClass}">${escapeHtml(typeShort)}</span>` +
      `<span class="activity-detail">${escapeHtml(detail)}</span></div>`;
  }
  container.innerHTML = html;
}

function renderResources(data: FleetState): void {
  const s = data.scale || ({} as any);
  const m = data.metrics || ({} as any);
  const active = data.pipelines ? data.pipelines.length : 0;

  const cores = m.cpuCores || s.cpuCores || 0;
  const maxByCpu = s.maxByCpu ?? null;
  const maxByMem = s.maxByMem ?? null;
  const maxByBudget = s.maxByBudget ?? null;

  const cpuBar = document.getElementById("res-cpu-bar");
  const cpuInfo = document.getElementById("res-cpu-info");
  if (cpuBar && cpuInfo) {
    if (maxByCpu != null) {
      const pct = maxByCpu > 0 ? Math.min((active / maxByCpu) * 100, 100) : 0;
      cpuBar.style.width = pct + "%";
      cpuBar.className = "resource-bar-fill";
      cpuInfo.textContent = maxByCpu + " max (" + cores + " cores)";
    } else {
      cpuBar.style.width = "0%";
      cpuInfo.textContent = "\u2014";
    }
  }

  const memBar = document.getElementById("res-mem-bar");
  const memInfo = document.getElementById("res-mem-info");
  if (memBar && memInfo) {
    if (maxByMem != null) {
      const pct = maxByMem > 0 ? Math.min((active / maxByMem) * 100, 100) : 0;
      memBar.style.width = pct + "%";
      memBar.className =
        maxByMem <= 1
          ? "resource-bar-fill critical"
          : maxByMem <= 2
            ? "resource-bar-fill warning"
            : "resource-bar-fill";
      const memGb = s.availMemGb != null ? s.availMemGb + "GB free" : "";
      memInfo.textContent =
        maxByMem + " max" + (memGb ? " (" + memGb + ")" : "");
    } else {
      memBar.style.width = "0%";
      memInfo.textContent = "\u2014";
    }
  }

  const budgetBar = document.getElementById("res-budget-bar");
  const budgetInfo = document.getElementById("res-budget-info");
  if (budgetBar && budgetInfo) {
    if (maxByBudget != null) {
      const pct =
        maxByBudget > 0 ? Math.min((active / maxByBudget) * 100, 100) : 0;
      budgetBar.style.width = pct + "%";
      budgetBar.className = "resource-bar-fill";
      budgetInfo.textContent = maxByBudget + " max";
    } else {
      budgetBar.style.width = "0%";
      budgetInfo.textContent = "unlimited";
    }
  }

  const constraintEl = document.getElementById("resource-constraint");
  if (constraintEl) {
    if (maxByMem != null && maxByCpu != null) {
      const minFactor = Math.min(
        maxByCpu || Infinity,
        maxByMem || Infinity,
        maxByBudget ?? Infinity,
      );
      if (minFactor === maxByMem && maxByMem <= 2) {
        constraintEl.innerHTML =
          '<span class="constraint-badge warning">MEM-BOUND</span>';
      } else if (maxByBudget != null && minFactor === maxByBudget) {
        constraintEl.innerHTML =
          '<span class="constraint-badge warning">BUDGET-BOUND</span>';
      } else {
        constraintEl.innerHTML =
          '<span class="constraint-badge nominal">NOMINAL</span>';
      }
    } else {
      constraintEl.innerHTML =
        '<span class="constraint-badge nominal">NOMINAL</span>';
    }
  }
}

function renderMachines(data: FleetState): void {
  const section = document.getElementById("machines-section");
  if (!section) return;
  const machines = data.machines || [];
  if (machines.length === 0) {
    section.style.display = "none";
    return;
  }
  section.style.display = "";
  const grid = document.getElementById("machines-grid");
  if (!grid) return;
  let html = "";
  for (const m of machines) {
    const statusCls =
      m.status === "online"
        ? "machine-online"
        : m.status === "degraded"
          ? "machine-degraded"
          : "machine-offline";
    html +=
      `<div class="machine-card ${statusCls}">` +
      `<div class="machine-card-header">` +
      `<span class="machine-name">${escapeHtml(m.name)}</span>` +
      `<span class="machine-status-dot"></span></div>` +
      `<div class="machine-card-body">` +
      `<span class="machine-host">${escapeHtml(m.host)}</span>` +
      `<span class="machine-workers">${m.active_workers}/${m.max_workers} workers</span>` +
      `</div></div>`;
  }
  grid.innerHTML = html;
}

export const overviewView: View = {
  init() {},
  render(data: FleetState) {
    renderStats(data);
    renderOverviewPipelines(data);
    renderQueue(data);
    renderOverviewActivity(data);
    renderResources(data);
    renderCostTicker(data);
    renderMachines(data);
  },
  destroy() {},
};
