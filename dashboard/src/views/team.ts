// Team tab - connected developers grid + team activity

import { store } from "../core/state";
import { escapeHtml, timeAgo } from "../core/helpers";
import { icon } from "../design/icons";
import * as api from "../core/api";
import type {
  FleetState,
  View,
  TeamData,
  TeamDeveloper,
  TeamActivityEvent,
} from "../types/api";

let teamRefreshTimer: ReturnType<typeof setInterval> | null = null;

function fetchTeamData(): void {
  api
    .fetchTeam()
    .then((data) => {
      store.set("teamCache", data);
      renderTeamGrid(data);
      renderTeamStats(data);
    })
    .catch(() => {});

  api
    .fetchTeamActivity()
    .then((events) => {
      store.set("teamActivityCache", events);
      renderTeamActivity(events);
    })
    .catch(() => {});
}

function renderTeamStats(data: TeamData): void {
  const el1 = document.getElementById("team-stat-online");
  if (el1) el1.textContent = String(data.total_online || 0);
  const el2 = document.getElementById("team-stat-pipelines");
  if (el2) el2.textContent = String(data.total_active_pipelines || 0);
  const el3 = document.getElementById("team-stat-queued");
  if (el3) el3.textContent = String(data.total_queued || 0);
}

function renderTeamGrid(data: TeamData): void {
  const grid = document.getElementById("team-grid");
  if (!grid) return;
  const devs = data.developers || [];
  if (devs.length === 0) {
    grid.innerHTML = `<div class="empty-state">${icon("users-round", 32)}<p>No developers connected. Run <code>shipwright connect start</code> to join.</p></div>`;
    return;
  }

  grid.innerHTML = devs
    .map((dev) => {
      const presence = dev._presence || "offline";
      const initials = (dev.developer_id || "?").substring(0, 2).toUpperCase();
      const pipelines = (dev.active_jobs || [])
        .map(
          (job) =>
            `<div class="team-card-pipeline-item">` +
            `<span class="team-card-pipeline-issue">#${escapeHtml(String(job.issue))}</span>` +
            `<span class="team-card-pipeline-stage">${escapeHtml(job.stage || "\u2014")}</span></div>`,
        )
        .join("");
      const pipelineSection = pipelines
        ? `<div class="team-card-pipelines">${pipelines}</div>`
        : "";

      return (
        `<div class="team-card"><div class="team-card-header">` +
        `<div class="team-card-avatar">${escapeHtml(initials)}</div>` +
        `<div class="team-card-info"><div class="team-card-name">${escapeHtml(dev.developer_id)}</div>` +
        `<div class="team-card-machine">${escapeHtml(dev.machine_name)}</div></div>` +
        `<div class="presence-dot ${presence}" title="${presence}"></div></div>` +
        `<div class="team-card-body">` +
        `<div class="team-card-row"><span class="team-card-row-label">Daemon</span>` +
        `<span class="team-card-row-value">${dev.daemon_running ? "\u25cf Running" : "\u25cb Stopped"}</span></div>` +
        `<div class="team-card-row"><span class="team-card-row-label">Active</span>` +
        `<span class="team-card-row-value">${(dev.active_jobs || []).length} pipelines</span></div>` +
        `<div class="team-card-row"><span class="team-card-row-label">Queued</span>` +
        `<span class="team-card-row-value">${(dev.queued || []).length} issues</span></div>` +
        pipelineSection +
        "</div></div>"
      );
    })
    .join("");
}

function renderTeamActivity(events: TeamActivityEvent[]): void {
  const container = document.getElementById("team-activity");
  if (!container) return;
  const items = Array.isArray(events) ? events : [];
  if (items.length === 0) {
    container.innerHTML =
      '<div class="empty-state">No team activity yet.</div>';
    return;
  }

  container.innerHTML = items
    .slice(0, 50)
    .map((evt) => {
      const isCI = evt.from_developer === "github-actions";
      const badgeClass = isCI ? "ci" : "local";
      const badgeText = isCI ? "CI" : evt.from_developer || "local";
      const text = formatTeamEvent(evt);
      const time = evt.ts ? timeAgo(new Date(evt.ts)) : "";
      return (
        `<div class="team-activity-item"><span class="source-badge ${badgeClass}">${escapeHtml(badgeText)}</span>` +
        `<div class="team-activity-content"><div class="team-activity-text">${text}</div>` +
        `<div class="team-activity-time">${time}</div></div></div>`
      );
    })
    .join("");
}

function formatTeamEvent(evt: TeamActivityEvent): string {
  const type = evt.type || "";
  const issue = evt.issue ? " #" + evt.issue : "";
  if (type.indexOf("pipeline.started") !== -1)
    return "Pipeline started" + issue;
  if (
    type.indexOf("pipeline.completed") !== -1 ||
    type.indexOf("pipeline_completed") !== -1
  ) {
    const result = evt.result === "success" ? "\u2713" : "\u2717";
    return "Pipeline " + result + issue;
  }
  if (type.indexOf("stage.") !== -1) {
    const stage = evt.stage || type.split(".").pop() || "";
    return "Stage " + escapeHtml(stage) + issue;
  }
  if (type.indexOf("daemon.") !== -1)
    return type.replace("daemon.", "Daemon: ");
  if (type.indexOf("ci.") !== -1) return type.replace("ci.", "CI: ") + issue;
  return escapeHtml(type) + issue;
}

function setupInviteButton(): void {
  const btn = document.getElementById("btn-create-invite");
  if (!btn) return;
  btn.addEventListener("click", () => {
    (btn as HTMLButtonElement).disabled = true;
    btn.textContent = "Creating...";
    api
      .createTeamInvite({ expires_hours: 72 })
      .then((data) => {
        const result = document.getElementById("team-invite-result");
        if (result) {
          result.style.display = "";
          result.innerHTML =
            `<div class="invite-link-box">` +
            `<span class="invite-label">Invite link (expires in 72h):</span>` +
            `<code class="invite-url" id="invite-url">${escapeHtml(data.url || data.token)}</code>` +
            `<button class="btn-sm" id="copy-invite">Copy</button></div>`;
          const copyBtn = document.getElementById("copy-invite");
          if (copyBtn) {
            copyBtn.addEventListener("click", () => {
              const url = data.url || data.token;
              navigator.clipboard.writeText(url).then(() => {
                copyBtn.textContent = "Copied!";
                setTimeout(() => {
                  copyBtn.textContent = "Copy";
                }, 2000);
              });
            });
          }
        }
      })
      .catch(() => {
        const result = document.getElementById("team-invite-result");
        if (result) {
          result.style.display = "";
          result.innerHTML =
            '<div class="invite-error">Failed to create invite. Check server logs.</div>';
        }
      })
      .finally(() => {
        (btn as HTMLButtonElement).disabled = false;
        btn.textContent = "Create Invite Link";
      });
  });
}

function loadIntegrationsStatus(): void {
  const container = document.getElementById("integrations-status");
  if (!container) return;

  api
    .fetchLinearStatus()
    .then((data) => {
      let html = '<div class="integrations-grid">';
      const connected = data.connected || data.configured || false;
      const statusCls = connected
        ? "integration-active"
        : "integration-inactive";
      const statusText = connected ? "Connected" : "Not configured";
      html +=
        `<div class="integration-card ${statusCls}">` +
        `<div class="integration-name">${icon("git-branch", 18)} Linear</div>` +
        `<div class="integration-status">${statusText}</div>`;
      if (data.workspace)
        html += `<div class="integration-detail">Workspace: ${escapeHtml(String(data.workspace))}</div>`;
      if (data.team_id)
        html += `<div class="integration-detail">Team: ${escapeHtml(String(data.team_id))}</div>`;
      html += "</div>";

      // GitHub (always available if dashboard is running)
      html +=
        `<div class="integration-card integration-active">` +
        `<div class="integration-name">${icon("git-branch", 18)} GitHub</div>` +
        `<div class="integration-status">Connected</div></div>`;

      html += "</div>";
      container.innerHTML = html;
    })
    .catch(() => {
      container.innerHTML =
        '<div class="empty-state"><p>Could not load status</p></div>';
    });
}

function setupAdminDebug(): void {
  const output = document.getElementById("admin-debug-output");
  if (!output) return;

  const renderJson = (data: unknown) => {
    output.innerHTML = `<pre class="admin-debug-pre">${escapeHtml(JSON.stringify(data, null, 2))}</pre>`;
  };

  document.getElementById("btn-db-health")?.addEventListener("click", () => {
    output.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';
    api
      .fetchDbHealth()
      .then(renderJson)
      .catch((e) => {
        output.innerHTML = `<div class="empty-state"><p>Error: ${escapeHtml(String(e))}</p></div>`;
      });
  });
  document.getElementById("btn-db-events")?.addEventListener("click", () => {
    output.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';
    api
      .fetchDbEvents(0, 50)
      .then(renderJson)
      .catch((e) => {
        output.innerHTML = `<div class="empty-state"><p>Error: ${escapeHtml(String(e))}</p></div>`;
      });
  });
  document.getElementById("btn-db-jobs")?.addEventListener("click", () => {
    output.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';
    api
      .fetchDbJobs()
      .then(renderJson)
      .catch((e) => {
        output.innerHTML = `<div class="empty-state"><p>Error: ${escapeHtml(String(e))}</p></div>`;
      });
  });
  document
    .getElementById("btn-db-heartbeats")
    ?.addEventListener("click", () => {
      output.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';
      api
        .fetchDbHeartbeats()
        .then(renderJson)
        .catch((e) => {
          output.innerHTML = `<div class="empty-state"><p>Error: ${escapeHtml(String(e))}</p></div>`;
        });
    });
  document.getElementById("btn-db-costs")?.addEventListener("click", () => {
    output.innerHTML = '<div class="empty-state"><p>Loading...</p></div>';
    api
      .fetchDbCostsToday()
      .then(renderJson)
      .catch((e) => {
        output.innerHTML = `<div class="empty-state"><p>Error: ${escapeHtml(String(e))}</p></div>`;
      });
  });
}

function setupClaimPanel(): void {
  const resultEl = document.getElementById("claim-result");
  const issueInput = document.getElementById("claim-issue") as HTMLInputElement;
  const machineInput = document.getElementById(
    "claim-machine",
  ) as HTMLInputElement;

  document.getElementById("btn-claim")?.addEventListener("click", () => {
    const issue = parseInt(issueInput?.value || "0");
    const machine = machineInput?.value.trim();
    if (!issue || !machine) {
      if (resultEl)
        resultEl.innerHTML =
          '<span style="color:var(--rose)">Issue # and machine name required</span>';
      return;
    }
    api
      .claimIssue(issue, machine)
      .then((data) => {
        if (resultEl) {
          if (data.approved) {
            resultEl.innerHTML = `<span style="color:var(--green)">Claimed #${issue} for ${escapeHtml(machine)}</span>`;
          } else {
            resultEl.innerHTML = `<span style="color:var(--amber)">Already claimed by ${escapeHtml(data.claimed_by || "unknown")}</span>`;
          }
        }
      })
      .catch((e) => {
        if (resultEl)
          resultEl.innerHTML = `<span style="color:var(--rose)">Error: ${escapeHtml(String(e))}</span>`;
      });
  });

  document.getElementById("btn-release")?.addEventListener("click", () => {
    const issue = parseInt(issueInput?.value || "0");
    const machine = machineInput?.value.trim();
    if (!issue) {
      if (resultEl)
        resultEl.innerHTML =
          '<span style="color:var(--rose)">Issue # required</span>';
      return;
    }
    api
      .releaseIssue(issue, machine || undefined)
      .then(() => {
        if (resultEl)
          resultEl.innerHTML = `<span style="color:var(--green)">Released claim on #${issue}</span>`;
      })
      .catch((e) => {
        if (resultEl)
          resultEl.innerHTML = `<span style="color:var(--rose)">Error: ${escapeHtml(String(e))}</span>`;
      });
  });
}

export const teamView: View = {
  init() {
    fetchTeamData();
    setupInviteButton();
    loadIntegrationsStatus();
    setupAdminDebug();
    setupClaimPanel();
    teamRefreshTimer = setInterval(fetchTeamData, 10000);
  },
  render(data: FleetState) {
    if (data.team) {
      renderTeamGrid(data.team);
      renderTeamStats(data.team);
    } else {
      const cache = store.get("teamCache");
      if (cache) {
        renderTeamGrid(cache);
        renderTeamStats(cache);
      }
    }
  },
  destroy() {
    if (teamRefreshTimer) {
      clearInterval(teamRefreshTimer);
      teamRefreshTimer = null;
    }
  },
};
