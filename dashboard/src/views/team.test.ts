import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { store } from "../core/state";
import type { FleetState, TeamData } from "../types/api";

vi.mock("../core/api", () => ({
  fetchTeam: vi
    .fn()
    .mockResolvedValue({
      developers: [],
      total_online: 0,
      total_active_pipelines: 0,
      total_queued: 0,
    }),
  fetchTeamActivity: vi.fn().mockResolvedValue([]),
  createTeamInvite: vi
    .fn()
    .mockResolvedValue({ url: "https://invite.example.com/abc" }),
  fetchLinearStatus: vi.fn().mockResolvedValue({ connected: false }),
  fetchDbHealth: vi.fn().mockResolvedValue({ ok: true }),
  fetchDbEvents: vi.fn().mockResolvedValue([]),
  fetchDbJobs: vi.fn().mockResolvedValue([]),
  fetchDbHeartbeats: vi.fn().mockResolvedValue([]),
  fetchDbCostsToday: vi.fn().mockResolvedValue([]),
  claimIssue: vi.fn().mockResolvedValue({ approved: true }),
  releaseIssue: vi.fn().mockResolvedValue({}),
}));

function createTeamDOM(): void {
  const grid = document.createElement("div");
  grid.id = "team-grid";
  document.body.appendChild(grid);

  const statOnline = document.createElement("span");
  statOnline.id = "team-stat-online";
  document.body.appendChild(statOnline);

  const statPipelines = document.createElement("span");
  statPipelines.id = "team-stat-pipelines";
  document.body.appendChild(statPipelines);

  const statQueued = document.createElement("span");
  statQueued.id = "team-stat-queued";
  document.body.appendChild(statQueued);

  const activity = document.createElement("div");
  activity.id = "team-activity";
  document.body.appendChild(activity);

  const inviteResult = document.createElement("div");
  inviteResult.id = "team-invite-result";
  inviteResult.style.display = "none";
  document.body.appendChild(inviteResult);

  const btnInvite = document.createElement("button");
  btnInvite.id = "btn-create-invite";
  document.body.appendChild(btnInvite);

  const integrations = document.createElement("div");
  integrations.id = "integrations-status";
  document.body.appendChild(integrations);

  const adminOutput = document.createElement("div");
  adminOutput.id = "admin-debug-output";
  document.body.appendChild(adminOutput);

  const claimResult = document.createElement("div");
  claimResult.id = "claim-result";
  document.body.appendChild(claimResult);

  const claimIssue = document.createElement("input");
  claimIssue.id = "claim-issue";
  document.body.appendChild(claimIssue);

  const claimMachine = document.createElement("input");
  claimMachine.id = "claim-machine";
  document.body.appendChild(claimMachine);

  const btnClaim = document.createElement("button");
  btnClaim.id = "btn-claim";
  document.body.appendChild(btnClaim);

  const btnRelease = document.createElement("button");
  btnRelease.id = "btn-release";
  document.body.appendChild(btnRelease);

  [
    "btn-db-health",
    "btn-db-events",
    "btn-db-jobs",
    "btn-db-heartbeats",
    "btn-db-costs",
  ].forEach((id) => {
    const btn = document.createElement("button");
    btn.id = id;
    document.body.appendChild(btn);
  });
}

function cleanupTeamDOM(): void {
  const ids = [
    "team-grid",
    "team-stat-online",
    "team-stat-pipelines",
    "team-stat-queued",
    "team-activity",
    "team-invite-result",
    "btn-create-invite",
    "integrations-status",
    "admin-debug-output",
    "claim-result",
    "claim-issue",
    "claim-machine",
    "btn-claim",
    "btn-release",
    "btn-db-health",
    "btn-db-events",
    "btn-db-jobs",
    "btn-db-heartbeats",
    "btn-db-costs",
  ];
  ids.forEach((id) => document.getElementById(id)?.remove());
}

function emptyFleetState(): FleetState {
  return {
    timestamp: new Date().toISOString(),
    daemon: {
      running: false,
      pid: null,
      uptime_s: 0,
      maxParallel: 0,
      pollInterval: 5,
    },
    pipelines: [],
    queue: [],
    events: [],
    scale: {},
    metrics: {},
    agents: [],
    machines: [],
    cost: { today_spent: 0, daily_budget: 0, pct_used: 0 },
    dora: {} as any,
  };
}

describe("TeamView", () => {
  beforeEach(() => {
    store.set("teamCache", null);
    createTeamDOM();
  });

  afterEach(() => {
    cleanupTeamDOM();
    vi.clearAllMocks();
  });

  it("renders team members when data provided", async () => {
    const { teamView } = await import("./team");
    const teamData: TeamData = {
      total_online: 2,
      total_active_pipelines: 1,
      total_queued: 0,
      developers: [
        {
          developer_id: "alice",
          machine_name: "macbook-pro",
          daemon_running: true,
          active_jobs: [{ issue: 42, title: "Fix bug", stage: "code" }],
          queued: [],
        },
      ],
    };
    const data = emptyFleetState();
    data.team = teamData;
    teamView.render(data);
    const grid = document.getElementById("team-grid");
    expect(grid).toBeTruthy();
    expect(grid!.innerHTML).toContain("alice");
    expect(grid!.innerHTML).toContain("macbook-pro");
    expect(grid!.innerHTML).toContain("#42");
    expect(grid!.innerHTML).toContain("presence-dot");
  });

  it("handles empty team", async () => {
    const { teamView } = await import("./team");
    const data = emptyFleetState();
    data.team = {
      developers: [],
      total_online: 0,
      total_active_pipelines: 0,
      total_queued: 0,
    };
    teamView.render(data);
    const grid = document.getElementById("team-grid");
    expect(grid).toBeTruthy();
    expect(grid!.innerHTML).toContain("No developers connected");
  });

  it("shows activity indicators when team has active jobs", async () => {
    const { teamView } = await import("./team");
    const teamData: TeamData = {
      developers: [
        {
          developer_id: "bob",
          machine_name: "dev-machine",
          daemon_running: true,
          active_jobs: [
            { issue: 10, stage: "plan" },
            { issue: 20, stage: "code" },
          ],
          queued: [30],
        },
      ],
    };
    const data = emptyFleetState();
    data.team = teamData;
    teamView.render(data);
    const grid = document.getElementById("team-grid");
    expect(grid!.innerHTML).toContain("team-card-pipeline-item");
    expect(grid!.innerHTML).toContain("#10");
    expect(grid!.innerHTML).toContain("#20");
  });

  it("uses teamCache when data.team is absent", async () => {
    const { teamView } = await import("./team");
    const cachedTeam: TeamData = {
      developers: [
        {
          developer_id: "cached",
          machine_name: "cache-machine",
          daemon_running: false,
          active_jobs: [],
          queued: [],
        },
      ],
      total_online: 1,
      total_active_pipelines: 0,
      total_queued: 0,
    };
    store.set("teamCache", cachedTeam);
    const data = emptyFleetState();
    data.team = undefined;
    teamView.render(data);
    const grid = document.getElementById("team-grid");
    expect(grid!.innerHTML).toContain("cached");
  });

  it("init and destroy do not throw", async () => {
    const { teamView } = await import("./team");
    expect(() => teamView.init()).not.toThrow();
    expect(() => teamView.destroy()).not.toThrow();
  });
});
