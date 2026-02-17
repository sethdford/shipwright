// Insights tab - failure patterns, patrol findings, decision log, failure heatmap

import { store } from "../core/state";
import { escapeHtml, formatTime } from "../core/helpers";
import { icon } from "../design/icons";
import * as api from "../core/api";
import type {
  FleetState,
  View,
  InsightsData,
  FailurePattern,
  Decision,
  PatrolFinding,
  HeatmapData,
} from "../types/api";

function fetchInsightsData(): void {
  const cache = store.get("insightsCache");
  if (cache) {
    renderInsightsTab(cache);
    return;
  }

  const panel = document.getElementById("panel-insights");
  if (panel)
    panel.innerHTML =
      '<div class="empty-state"><p>Loading insights...</p></div>';

  const results: InsightsData = {
    patterns: null,
    decisions: null,
    patrol: null,
    heatmap: null,
    globalLearnings: null,
  };
  let pending = 5;

  function checkDone() {
    pending--;
    if (pending <= 0) {
      store.set("insightsCache", results);
      renderInsightsTab(results);
    }
  }

  api
    .fetchPatterns()
    .then((d) => {
      results.patterns = d.patterns || [];
    })
    .catch(() => {
      results.patterns = [];
    })
    .then(checkDone);
  api
    .fetchDecisions()
    .then((d) => {
      results.decisions = d.decisions || [];
    })
    .catch(() => {
      results.decisions = [];
    })
    .then(checkDone);
  api
    .fetchPatrol()
    .then((d) => {
      results.patrol = d.findings || [];
    })
    .catch(() => {
      results.patrol = [];
    })
    .then(checkDone);
  api
    .fetchHeatmap()
    .then((d) => {
      results.heatmap = d;
    })
    .catch(() => {
      results.heatmap = null;
    })
    .then(checkDone);
  api
    .fetchGlobalLearnings()
    .then((d) => {
      results.globalLearnings = d.learnings || [];
    })
    .catch(() => {
      results.globalLearnings = [];
    })
    .then(checkDone);
}

function renderInsightsTab(data: InsightsData): void {
  const panel = document.getElementById("panel-insights");
  if (!panel) return;

  let html = '<div class="insights-grid">';
  html +=
    `<div class="insights-section"><div class="section-header"><h3>${icon("lightbulb", 18)} Failure Patterns</h3></div>` +
    `<div id="failure-patterns-content">${renderFailurePatterns(data.patterns || [])}</div></div>`;
  html +=
    `<div class="insights-section"><div class="section-header"><h3>${icon("shield-alert", 18)} Patrol Findings</h3></div>` +
    `<div id="patrol-findings-content">${renderPatrolFindings(data.patrol || [])}</div></div>`;
  html +=
    `<div class="insights-section insights-full-width"><div class="section-header"><h3>${icon("git-branch", 18)} Decision Log</h3></div>` +
    `<div id="decision-log-content">${renderDecisionLog(data.decisions || [])}</div></div>`;
  html +=
    `<div class="insights-section insights-full-width"><div class="section-header"><h3>${icon("bar-chart-3", 18)} Failure Heatmap</h3></div>` +
    `<div id="failure-heatmap-content">${renderFailureHeatmap(data.heatmap)}</div></div>`;
  html +=
    `<div class="insights-section insights-full-width"><div class="section-header"><h3>${icon("brain", 18)} Global Learnings</h3></div>` +
    `<div id="global-learnings-content">${renderGlobalLearnings(data.globalLearnings || [])}</div></div>`;
  html +=
    `<div class="insights-section insights-full-width"><div class="section-header"><h3>${icon("clipboard-list", 18)} Audit Log</h3></div>` +
    `<div id="audit-log-content"><div class="empty-state"><p>Loading...</p></div></div></div>`;
  html += "</div>";
  panel.innerHTML = html;

  // Load audit log asynchronously
  const auditContainer = document.getElementById("audit-log-content");
  if (auditContainer) {
    api
      .fetchAuditLog()
      .then((data) => {
        const entries = data.entries || [];
        if (entries.length === 0) {
          auditContainer.innerHTML =
            '<div class="empty-state"><p>No audit entries. Human interventions will appear here.</p></div>';
          return;
        }
        let html2 = '<div class="audit-list">';
        for (const e of entries.slice(0, 50)) {
          const ts = e.ts ? formatTime(String(e.ts)) : "";
          const action = String(e.action || "unknown");
          const issue = e.issue ? ` #${e.issue}` : "";
          const details = Object.entries(e)
            .filter(([k]) => !["ts", "ts_epoch", "action", "issue"].includes(k))
            .map(([k, v]) => `${k}: ${String(v)}`)
            .join(", ");
          html2 +=
            `<div class="audit-entry"><span class="audit-ts">${ts}</span>` +
            `<span class="audit-action">${escapeHtml(action)}${issue}</span>` +
            (details
              ? `<span class="audit-details">${escapeHtml(details)}</span>`
              : "") +
            "</div>";
        }
        html2 += "</div>";
        auditContainer.innerHTML = html2;
      })
      .catch(() => {
        auditContainer.innerHTML =
          '<div class="empty-state"><p>Could not load audit log</p></div>';
      });
  }
}

function renderFailurePatterns(patterns: FailurePattern[]): string {
  if (!patterns.length)
    return '<div class="empty-state"><p>No failure patterns recorded</p></div>';
  const sorted = [...patterns].sort(
    (a, b) => (b.frequency || b.count || 0) - (a.frequency || a.count || 0),
  );
  let html = "";
  for (const p of sorted) {
    const freq = p.frequency || p.count || 0;
    html +=
      `<div class="pattern-card"><div class="pattern-card-header">` +
      `<span class="pattern-desc">${escapeHtml(p.description || p.pattern || "")}</span>` +
      `<span class="pattern-freq-badge">${freq}x</span></div>`;
    if (p.root_cause)
      html += `<div class="pattern-detail"><span class="pattern-label">Root cause:</span> ${escapeHtml(p.root_cause)}</div>`;
    if (p.fix || p.suggested_fix)
      html += `<div class="pattern-detail pattern-fix"><span class="pattern-label">Fix:</span> ${escapeHtml(p.fix || p.suggested_fix || "")}</div>`;
    html += "</div>";
  }
  return html;
}

function renderPatrolFindings(findings: PatrolFinding[]): string {
  if (!findings.length)
    return '<div class="empty-state"><p>No patrol findings</p></div>';
  let html = "";
  for (const f of findings) {
    const severity = (f.severity || "low").toLowerCase();
    html +=
      `<div class="patrol-card"><div class="patrol-card-header">` +
      `<span class="patrol-severity-badge severity-${escapeHtml(severity)}">${escapeHtml(severity.toUpperCase())}</span>` +
      `<span class="patrol-type">${escapeHtml(f.type || f.category || "")}</span></div>` +
      `<div class="patrol-desc">${escapeHtml(f.description || f.message || "")}</div>` +
      (f.file ? `<div class="patrol-file">${escapeHtml(f.file)}</div>` : "") +
      "</div>";
  }
  return html;
}

function renderDecisionLog(decisions: Decision[]): string {
  if (!decisions.length)
    return '<div class="empty-state"><p>No decisions logged</p></div>';
  let html = '<div class="decision-list">';
  for (const d of decisions) {
    html +=
      `<div class="decision-row">` +
      `<span class="decision-ts">${formatTime(d.timestamp || d.ts)}</span>` +
      `<span class="decision-action">${escapeHtml(d.action || d.decision || "")}</span>` +
      `<span class="decision-outcome">${escapeHtml(d.outcome || d.result || "")}</span>` +
      (d.issue ? `<span class="decision-issue">#${d.issue}</span>` : "") +
      "</div>";
  }
  html += "</div>";
  return html;
}

function renderGlobalLearnings(
  learnings: Array<Record<string, unknown>>,
): string {
  if (!learnings.length)
    return '<div class="empty-state"><p>No global learnings yet. Agents accumulate learnings across pipelines.</p></div>';
  let html = '<div class="learnings-list">';
  for (const l of learnings) {
    const category = String(l.category || l.type || "general");
    const content = String(l.content || l.description || l.learning || "");
    const source = l.source
      ? `<span class="learning-source">${escapeHtml(String(l.source))}</span>`
      : "";
    const ts = l.timestamp || l.ts;
    const time = ts
      ? `<span class="learning-time">${formatTime(String(ts))}</span>`
      : "";
    html +=
      `<div class="learning-card">` +
      `<div class="learning-header"><span class="learning-category">${escapeHtml(category)}</span>${source}${time}</div>` +
      `<div class="learning-content">${escapeHtml(content)}</div></div>`;
  }
  html += "</div>";
  return html;
}

function renderFailureHeatmap(data: HeatmapData | null): string {
  if (!data?.heatmap)
    return '<div class="empty-state"><p>No heatmap data</p></div>';

  const heatmap = data.heatmap;
  const stages = Object.keys(heatmap);
  if (stages.length === 0)
    return '<div class="empty-state"><p>No heatmap data</p></div>';

  const daysSet = new Set<string>();
  for (const stage of stages) {
    for (const day of Object.keys(heatmap[stage])) daysSet.add(day);
  }
  const days = Array.from(daysSet).sort();
  if (days.length === 0)
    return '<div class="empty-state"><p>No heatmap data</p></div>';

  let maxCount = 0;
  for (const stage of stages) {
    for (const day of days) {
      const count = heatmap[stage]?.[day] || 0;
      if (count > maxCount) maxCount = count;
    }
  }
  if (maxCount === 0) maxCount = 1;

  let html = `<div class="heatmap-grid" style="grid-template-columns: 100px repeat(${days.length}, 1fr)">`;
  html += '<div class="heatmap-corner"></div>';
  for (const d of days) {
    const parts = d.split("-");
    const label = parts.length >= 3 ? parts[1] + "/" + parts[2] : d;
    html += `<div class="heatmap-day-label">${escapeHtml(label)}</div>`;
  }

  for (const s of stages) {
    html += `<div class="heatmap-stage-label">${escapeHtml(s)}</div>`;
    for (const d of days) {
      const count = heatmap[s]?.[d] || 0;
      const intensity = count / maxCount;
      const bgColor =
        count === 0
          ? "transparent"
          : `rgba(244, 63, 94, ${(0.2 + intensity * 0.8).toFixed(2)})`;
      html += `<div class="heatmap-cell" style="background:${bgColor}" title="${escapeHtml(s)} ${escapeHtml(d)}: ${count} failures">${count > 0 ? count : ""}</div>`;
    }
  }
  html += "</div>";
  return html;
}

export const insightsView: View = {
  init() {
    fetchInsightsData();
  },
  render(_data: FleetState) {
    const cache = store.get("insightsCache");
    if (cache) renderInsightsTab(cache);
  },
  destroy() {},
};
