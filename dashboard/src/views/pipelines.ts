// Pipelines tab - table, filters, detail panel, artifact viewer

import { store } from "../core/state";
import { escapeHtml, formatDuration, formatMarkdown } from "../core/helpers";
import { renderPipelineSVG } from "../components/charts/pipeline-rail";
import { renderLogViewer } from "../components/terminal";
import { updateBulkToolbar } from "../components/modal";
import { icon } from "../design/icons";
import { STAGE_SHORT } from "../design/tokens";
import * as api from "../core/api";
import type { FleetState, View, PipelineDetail } from "../types/api";

let localPipelineDetail: PipelineDetail | null = null;

function setupPipelineFilters(): void {
  const chips = document.querySelectorAll("#pipeline-filters .filter-chip");
  chips.forEach((chip) => {
    chip.addEventListener("click", () => {
      const filter = chip.getAttribute("data-filter") || "all";
      store.set("pipelineFilter", filter);
      const siblings = document.querySelectorAll(
        "#pipeline-filters .filter-chip",
      );
      siblings.forEach((s) => s.classList.remove("active"));
      chip.classList.add("active");
      const data = store.get("fleetState");
      if (data) renderPipelinesTab(data);
    });
  });

  const closeBtn = document.getElementById("detail-panel-close");
  if (closeBtn) closeBtn.addEventListener("click", closePipelineDetail);
}

function renderPipelinesTab(data: FleetState): void {
  const tbody = document.getElementById("pipeline-table-body");
  if (!tbody) return;

  const pipelines = data.pipelines || [];
  const events = data.events || [];
  const pipelineFilter = store.get("pipelineFilter");
  const selectedPipelineIssue = store.get("selectedPipelineIssue");
  const selectedIssues = store.get("selectedIssues");

  interface PipelineRow {
    issue: number;
    title: string;
    status: string;
    stage: string;
    elapsed_s: number | null;
    branch: string;
  }

  const rows: PipelineRow[] = [];
  for (const p of pipelines) {
    rows.push({
      issue: p.issue,
      title: p.title || "",
      status: "active",
      stage:
        (STAGE_SHORT as Record<string, string>)[p.stage] || p.stage || "\u2014",
      elapsed_s: p.elapsed_s,
      branch: p.worktree || "",
    });
  }

  const seen: Record<number, boolean> = {};
  rows.forEach((r) => (seen[r.issue] = true));

  for (let i = events.length - 1; i >= 0; i--) {
    const ev = events[i];
    if (!ev.issue || seen[ev.issue]) continue;
    const typeRaw = String(ev.type || "");
    if (typeRaw.includes("completed") || typeRaw.includes("failed")) {
      const st = typeRaw.includes("failed") ? "failed" : "completed";
      rows.push({
        issue: ev.issue,
        title: ev.issueTitle || ev.title || "",
        status: st,
        stage: st === "completed" ? "DONE" : "FAIL",
        elapsed_s: ev.duration_s ?? null,
        branch: "",
      });
      seen[ev.issue] = true;
    }
  }

  let filtered = rows;
  if (pipelineFilter !== "all") {
    filtered = rows.filter((r) => r.status === pipelineFilter);
  }

  if (filtered.length === 0) {
    tbody.innerHTML =
      '<tr><td colspan="7" class="empty-state"><p>No pipelines match filter</p></td></tr>';
    return;
  }

  let html = "";
  for (const r of filtered) {
    const selectedClass =
      selectedPipelineIssue == r.issue ? " row-selected" : "";
    const isChecked = selectedIssues[r.issue] ? " checked" : "";
    html +=
      `<tr class="pipeline-row${selectedClass}" data-issue="${r.issue}">` +
      `<td class="col-checkbox"><input type="checkbox" class="pipeline-checkbox" data-issue="${r.issue}"${isChecked}></td>` +
      `<td class="col-issue">#${r.issue}</td>` +
      `<td class="col-title">${escapeHtml(r.title)}</td>` +
      `<td><span class="status-badge ${r.status}">${r.status.toUpperCase()}</span></td>` +
      `<td class="col-stage">${escapeHtml(r.stage)}</td>` +
      `<td class="col-duration">${formatDuration(r.elapsed_s)}</td>` +
      `<td class="col-branch">${escapeHtml(r.branch)}</td></tr>`;
  }
  tbody.innerHTML = html;

  // Checkbox handlers
  tbody.querySelectorAll(".pipeline-checkbox").forEach((cb) => {
    cb.addEventListener("change", (e) => {
      e.stopPropagation();
      const el = e.target as HTMLInputElement;
      const iss = el.getAttribute("data-issue") || "";
      const issues = { ...store.get("selectedIssues") };
      if (el.checked) issues[iss] = true;
      else delete issues[iss];
      store.set("selectedIssues", issues);
      updateBulkToolbar();
    });
    cb.addEventListener("click", (e) => e.stopPropagation());
  });

  // Select-all
  const selectAll = document.getElementById(
    "pipeline-select-all",
  ) as HTMLInputElement;
  if (selectAll) {
    selectAll.addEventListener("change", () => {
      const cbs = tbody.querySelectorAll(
        ".pipeline-checkbox",
      ) as NodeListOf<HTMLInputElement>;
      const issues: Record<string, boolean> = {};
      cbs.forEach((cb) => {
        cb.checked = selectAll.checked;
        const iss = cb.getAttribute("data-issue") || "";
        if (selectAll.checked) issues[iss] = true;
      });
      store.set("selectedIssues", selectAll.checked ? issues : {});
      updateBulkToolbar();
    });
  }

  // Row click handlers
  tbody.querySelectorAll(".pipeline-row").forEach((tr) => {
    tr.addEventListener("click", () => {
      const issue = tr.getAttribute("data-issue");
      if (!issue) return;
      if (store.get("selectedPipelineIssue") == Number(issue)) {
        closePipelineDetail();
      } else {
        fetchPipelineDetail(Number(issue));
      }
    });
  });
}

export function fetchPipelineDetail(issue: number): void {
  store.set("selectedPipelineIssue", issue);

  document
    .querySelectorAll("#pipeline-table-body .pipeline-row")
    .forEach((tr) => {
      if (tr.getAttribute("data-issue") == String(issue))
        tr.classList.add("row-selected");
      else tr.classList.remove("row-selected");
    });

  const panel = document.getElementById("pipeline-detail-panel");
  const title = document.getElementById("detail-panel-title");
  const body = document.getElementById("detail-panel-body");
  if (title) title.textContent = "Pipeline #" + issue;
  if (body) body.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';
  if (panel) panel.classList.add("open");

  api
    .fetchPipelineDetail(issue)
    .then((detail) => {
      localPipelineDetail = detail;
      store.set("pipelineDetail", detail);
      renderPipelineDetail(detail);
    })
    .catch((err) => {
      if (body)
        body.innerHTML = `<div class="empty-state"><p>Failed to load: ${escapeHtml(String(err))}</p></div>`;
    });
}

function renderPipelineDetail(detail: PipelineDetail): void {
  const body = document.getElementById("detail-panel-body");
  if (!body) return;
  const issue = detail.issue || store.get("selectedPipelineIssue");
  let html = "";

  html += `<div id="github-status-${issue}" class="github-status-banner"></div>`;
  const stagesDone = detail.stageHistory?.map((h) => h.stage) || [];
  html += `<div class="pipeline-svg-wrap">${renderPipelineSVG({
    stagesDone,
    stage: detail.stage,
    status: "",
    issue: detail.issue,
    title: detail.title,
    elapsed_s: detail.elapsed_s,
    iteration: 0,
    maxIterations: 0,
  })}</div>`;

  const history = detail.stageHistory || [];
  if (history.length > 0) {
    html += '<div class="stage-timeline">';
    for (const sh of history) {
      const isActive = sh.stage === detail.stage;
      const dotCls = isActive ? "active" : "done";
      html +=
        `<div class="stage-timeline-item">` +
        `<div class="stage-timeline-dot ${dotCls}"></div>` +
        `<span class="stage-timeline-name">${escapeHtml(sh.stage)}</span>` +
        `<span class="stage-timeline-duration">${formatDuration(sh.duration_s)}</span></div>`;
    }
    html += "</div>";
  }

  html += '<div class="detail-meta-row">';
  if (detail.branch)
    html += `<div class="detail-meta-item">Branch: <span>${escapeHtml(detail.branch)}</span></div>`;
  if (detail.elapsed_s != null)
    html += `<div class="detail-meta-item">Elapsed: <span>${formatDuration(detail.elapsed_s)}</span></div>`;
  if (detail.prLink)
    html += `<div class="detail-meta-item">PR: <a href="${escapeHtml(detail.prLink)}" target="_blank">${escapeHtml(detail.prLink)}</a></div>`;
  html += "</div>";

  // Quality gate display
  html += `<div class="quality-gate-panel" id="quality-gate-${issue}" style="display:none"></div>`;

  // Approval gate placeholder
  html += `<div class="approval-gate-banner" id="approval-gate-${issue}" style="display:none"></div>`;

  html += renderArtifactViewer(issue!, detail);
  body.innerHTML = html;

  if (issue) {
    renderGitHubStatus(issue);
    setupArtifactTabs(issue);
    checkApprovalGate(issue, detail.stage);
    loadQualityGates(issue);
  }
}

function renderArtifactViewer(issue: number, detail: PipelineDetail): string {
  const tabs = [
    { key: "plan", label: "Plan", content: detail.plan },
    { key: "design", label: "Design", content: detail.design },
    { key: "dod", label: "DoD", content: detail.dod },
    { key: "reasoning", label: "Reasoning", content: null },
    { key: "failures", label: "Failures", content: null },
    { key: "tests", label: "Tests", content: null },
    { key: "review", label: "Review", content: null },
    { key: "logs", label: "Logs", content: null },
  ];

  let html = '<div class="artifact-viewer"><div class="artifact-tabs">';
  for (let i = 0; i < tabs.length; i++) {
    const activeClass = i === 0 ? " active" : "";
    html += `<button class="artifact-tab-btn${activeClass}" data-artifact="${tabs[i].key}" data-issue="${issue}">${escapeHtml(tabs[i].label)}</button>`;
  }
  html += "</div>";
  html += `<div class="artifact-content" id="artifact-content-${issue}">`;
  if (detail.plan) {
    html += `<div class="detail-plan-content">${formatMarkdown(detail.plan)}</div>`;
  } else {
    html += '<div class="empty-state"><p>No plan data</p></div>';
  }
  html += "</div></div>";
  return html;
}

function setupArtifactTabs(issue: number): void {
  const btns = document.querySelectorAll(
    `.artifact-tab-btn[data-issue="${issue}"]`,
  );
  btns.forEach((btn) => {
    btn.addEventListener("click", () => {
      const artifact = btn.getAttribute("data-artifact");
      const iss = btn.getAttribute("data-issue");
      const siblings = document.querySelectorAll(
        `.artifact-tab-btn[data-issue="${iss}"]`,
      );
      siblings.forEach((s) => s.classList.remove("active"));
      btn.classList.add("active");
      if (iss && artifact) fetchArtifact(Number(iss), artifact);
    });
  });
}

function fetchArtifact(issue: number, type: string): void {
  const container = document.getElementById("artifact-content-" + issue);
  if (!container) return;
  container.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';

  if (localPipelineDetail) {
    if (type === "plan" && localPipelineDetail.plan) {
      container.innerHTML = `<div class="detail-plan-content">${formatMarkdown(localPipelineDetail.plan)}</div>`;
      return;
    }
    if (type === "design" && localPipelineDetail.design) {
      container.innerHTML = `<div class="detail-plan-content">${formatMarkdown(localPipelineDetail.design)}</div>`;
      return;
    }
    if (type === "dod" && localPipelineDetail.dod) {
      container.innerHTML = `<div class="detail-plan-content">${formatMarkdown(localPipelineDetail.dod)}</div>`;
      return;
    }
  }

  // Handle special artifact types
  if (type === "reasoning") {
    api
      .fetchPipelineReasoning(issue)
      .then((data) => {
        const reasoning = data.reasoning || [];
        if (reasoning.length === 0) {
          container.innerHTML =
            '<div class="empty-state"><p>No reasoning data available. Agent reasoning will appear here as stages complete.</p></div>';
          return;
        }
        let html = '<div class="reasoning-list">';
        for (const r of reasoning) {
          const stage = String(r.stage || "general");
          const content = String(r.content || r.summary || r.description || "");
          html +=
            `<div class="reasoning-entry">` +
            `<div class="reasoning-stage">${escapeHtml(stage)}</div>` +
            `<div class="reasoning-content">${r.type === "markdown" ? formatMarkdown(content) : escapeHtml(content)}</div></div>`;
        }
        html += "</div>";
        container.innerHTML = html;
      })
      .catch(() => {
        container.innerHTML =
          '<div class="empty-state"><p>Could not load reasoning data</p></div>';
      });
    return;
  }

  if (type === "failures") {
    api
      .fetchPipelineFailures(issue)
      .then((data) => {
        const failures = data.failures || [];
        if (failures.length === 0) {
          container.innerHTML =
            '<div class="empty-state"><p>No failures recorded for this pipeline.</p></div>';
          return;
        }
        let html = '<div class="failure-analysis-list">';
        for (const f of failures) {
          const fType = String(f.type || f.stage || "unknown");
          const desc = String(f.description || f.error || f.message || "");
          const rootCause = f.root_cause
            ? `<div class="failure-root-cause"><strong>Root cause:</strong> ${escapeHtml(String(f.root_cause))}</div>`
            : "";
          const fix = f.fix || f.suggested_fix;
          const fixHtml = fix
            ? `<div class="failure-fix"><strong>Fix:</strong> ${escapeHtml(String(fix))}</div>`
            : "";
          html +=
            `<div class="failure-entry">` +
            `<div class="failure-type">${escapeHtml(fType)}</div>` +
            `<div class="failure-desc">${escapeHtml(desc)}</div>` +
            rootCause +
            fixHtml +
            "</div>";
        }
        html += "</div>";
        container.innerHTML = html;
      })
      .catch(() => {
        container.innerHTML =
          '<div class="empty-state"><p>Could not load failure data</p></div>';
      });
    return;
  }

  api
    .fetchArtifact(issue, type)
    .then((data) => {
      if (type === "logs") {
        container.innerHTML = renderLogViewer(data.content || "");
      } else {
        container.innerHTML = `<div class="detail-plan-content">${formatMarkdown(data.content || "")}</div>`;
      }
    })
    .catch((err) => {
      container.innerHTML = `<div class="empty-state"><p>Not available: ${escapeHtml(String(err))}</p></div>`;
    });
}

function renderGitHubStatus(issue: number): void {
  const container = document.getElementById("github-status-" + issue);
  if (!container) return;

  api
    .fetchGitHubStatus(issue)
    .then((data) => {
      if (!(data as any).configured) {
        container.innerHTML = "";
        return;
      }
      let html = '<div class="github-banner">';
      if ((data as any).issue_state)
        html += `<span class="github-badge ${escapeHtml((data as any).issue_state)}">${escapeHtml((data as any).issue_state)}</span>`;
      if ((data as any).pr_number)
        html += `<a class="github-link" href="${escapeHtml((data as any).pr_url || "")}" target="_blank">PR #${(data as any).pr_number}</a>`;
      if ((data as any).checks?.length > 0) {
        html += '<span class="github-checks">';
        for (const check of (data as any).checks) {
          const ci =
            check.status === "success"
              ? "\u2713"
              : check.status === "failure"
                ? "\u2717"
                : "\u25CF";
          const cls =
            check.status === "success"
              ? "github-badge success"
              : check.status === "failure"
                ? "github-badge failure"
                : "github-badge pending";
          html += `<span class="${cls}" title="${escapeHtml(check.name || "")}">${ci}</span>`;
        }
        html += "</span>";
      }
      html += "</div>";
      container.innerHTML = html;
    })
    .catch(() => {
      container.innerHTML = "";
    });
}

function renderErrorHighlight(issue: number): void {
  const container = document.getElementById("error-highlight-" + issue);
  if (!container) return;

  api
    .fetchLogs(issue)
    .then((data) => {
      const content = data.content || "";
      const lines = content.split("\n");
      const errorLines = lines.filter((l) => {
        const lower = l.toLowerCase();
        return lower.indexOf("error") !== -1 || lower.indexOf("fail") !== -1;
      });
      if (errorLines.length === 0) {
        container.innerHTML = "";
        return;
      }
      const lastError = errorLines[errorLines.length - 1];
      container.innerHTML =
        `<div class="error-highlight"><span class="error-highlight-title">LAST ERROR</span>` +
        `<pre class="error-highlight-content">${escapeHtml(lastError)}</pre></div>`;
    })
    .catch(() => {
      container.innerHTML = "";
    });
}

function loadQualityGates(issue: number): void {
  const panel = document.getElementById("quality-gate-" + issue);
  if (!panel) return;

  api
    .fetchPipelineQuality(issue)
    .then((data) => {
      const results = data.results || [];
      if (results.length === 0) {
        panel.style.display = "none";
        return;
      }
      panel.style.display = "";
      const allPassed = results.every((r) => r.passed);
      let html = `<div class="quality-gate-header"><span class="quality-icon">${allPassed ? "\u2705" : "\u26A0\uFE0F"}</span>`;
      html += `<span class="quality-title">Quality Gates${allPassed ? " - All Passing" : ""}</span></div>`;
      html += '<div class="quality-gate-rules">';
      for (const r of results) {
        const statusCls = r.passed ? "gate-pass" : "gate-fail";
        const statusIcon = r.passed ? "\u2713" : "\u2717";
        const valueStr =
          r.value !== null && r.value !== undefined ? String(r.value) : "N/A";
        html +=
          `<div class="quality-gate-rule ${statusCls}">` +
          `<span class="gate-status">${statusIcon}</span>` +
          `<span class="gate-name">${escapeHtml(r.name.replace(/_/g, " "))}</span>` +
          `<span class="gate-threshold">${r.operator} ${r.threshold}</span>` +
          `<span class="gate-value">Current: ${escapeHtml(valueStr)}</span></div>`;
      }
      html += "</div>";
      panel.innerHTML = html;
    })
    .catch(() => {
      panel.style.display = "none";
    });
}

function checkApprovalGate(issue: number, currentStage: string): void {
  const banner = document.getElementById("approval-gate-" + issue);
  if (!banner) return;

  api
    .fetchApprovalGates()
    .then((config) => {
      if (!config.enabled) {
        banner.style.display = "none";
        return;
      }
      // Check if current stage requires approval
      const gatedStages = config.stages || [];
      const pending = (config.pending || []).find((p) => p.issue === issue);

      if (pending) {
        banner.style.display = "";
        banner.innerHTML =
          `<div class="approval-gate-waiting">` +
          `<span class="approval-icon">\u{1F6D1}</span>` +
          `<span>Awaiting approval to proceed to <strong>${escapeHtml(pending.stage)}</strong></span>` +
          `<div class="approval-actions">` +
          `<button class="btn-primary btn-sm" id="approve-${issue}">Approve</button>` +
          `<button class="btn-danger btn-sm" id="reject-${issue}">Reject</button></div></div>`;
        document
          .getElementById("approve-" + issue)
          ?.addEventListener("click", () => {
            api.approveGate(issue, pending.stage).then(() => {
              banner.innerHTML =
                '<div class="approval-approved">Approved. Agent will proceed.</div>';
              setTimeout(() => {
                banner.style.display = "none";
              }, 3000);
            });
          });
        document
          .getElementById("reject-" + issue)
          ?.addEventListener("click", () => {
            const reason = prompt("Reason for rejection (optional):");
            api
              .rejectGate(issue, pending.stage, reason || undefined)
              .then(() => {
                banner.innerHTML =
                  '<div class="approval-rejected">Rejected. Agent will stop.</div>';
                setTimeout(() => {
                  banner.style.display = "none";
                }, 3000);
              });
          });
      } else if (gatedStages.includes(currentStage)) {
        banner.style.display = "";
        banner.innerHTML =
          `<div class="approval-gate-info">` +
          `<span class="approval-icon">\u{1F512}</span>` +
          `<span>Approval gates are enabled for: ${gatedStages.map((s) => escapeHtml(s)).join(", ")}</span></div>`;
      } else {
        banner.style.display = "none";
      }
    })
    .catch(() => {
      banner.style.display = "none";
    });
}

function closePipelineDetail(): void {
  store.set("selectedPipelineIssue", null);
  store.set("pipelineDetail", null);
  localPipelineDetail = null;
  const panel = document.getElementById("pipeline-detail-panel");
  if (panel) panel.classList.remove("open");
  document
    .querySelectorAll("#pipeline-table-body .pipeline-row")
    .forEach((tr) => tr.classList.remove("row-selected"));
}

export const pipelinesView: View = {
  init() {
    setupPipelineFilters();
  },
  render(data: FleetState) {
    renderPipelinesTab(data);
  },
  destroy() {},
};
