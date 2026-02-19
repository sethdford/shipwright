import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { store } from "../core/state";
import type { FleetState } from "../types/api";

vi.mock("../core/api", () => ({
  fetchPipelineDetail: vi.fn().mockResolvedValue({}),
  fetchPipelineReasoning: vi.fn().mockResolvedValue({ reasoning: [] }),
  fetchPipelineFailures: vi.fn().mockResolvedValue({ failures: [] }),
  fetchArtifact: vi.fn().mockResolvedValue({ content: "" }),
  fetchGitHubStatus: vi.fn().mockResolvedValue({ configured: false }),
  fetchPipelineQuality: vi.fn().mockResolvedValue({ results: [] }),
  fetchApprovalGates: vi.fn().mockResolvedValue({ enabled: false }),
  fetchLogs: vi.fn().mockResolvedValue({ content: "" }),
}));

vi.mock("../components/modal", () => ({
  updateBulkToolbar: vi.fn(),
}));

function createPipelinesDOM(): void {
  const tbody = document.createElement("tbody");
  tbody.id = "pipeline-table-body";
  document.body.appendChild(tbody);

  const filters = document.createElement("div");
  filters.id = "pipeline-filters";
  const chipAll = document.createElement("span");
  chipAll.className = "filter-chip active";
  chipAll.setAttribute("data-filter", "all");
  filters.appendChild(chipAll);
  document.body.appendChild(filters);

  const closeBtn = document.createElement("button");
  closeBtn.id = "detail-panel-close";
  document.body.appendChild(closeBtn);

  const selectAll = document.createElement("input");
  selectAll.id = "pipeline-select-all";
  selectAll.type = "checkbox";
  document.body.appendChild(selectAll);

  const panel = document.createElement("div");
  panel.id = "pipeline-detail-panel";
  const title = document.createElement("div");
  title.id = "detail-panel-title";
  const body = document.createElement("div");
  body.id = "detail-panel-body";
  panel.appendChild(title);
  panel.appendChild(body);
  document.body.appendChild(panel);
}

function cleanupPipelinesDOM(): void {
  [
    "pipeline-table-body",
    "pipeline-filters",
    "detail-panel-close",
    "pipeline-select-all",
    "pipeline-detail-panel",
  ].forEach((id) => document.getElementById(id)?.remove());
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

describe("PipelinesView", () => {
  beforeEach(() => {
    store.set("pipelineFilter", "all");
    store.set("selectedPipelineIssue", null);
    store.set("selectedIssues", {});
    store.set("fleetState", emptyFleetState());
    createPipelinesDOM();
  });

  afterEach(() => {
    cleanupPipelinesDOM();
    vi.clearAllMocks();
  });

  it("renders pipeline list from mock data", async () => {
    const { pipelinesView } = await import("./pipelines");
    pipelinesView.init();
    const data = emptyFleetState();
    data.pipelines = [
      {
        issue: 100,
        title: "Add feature X",
        stage: "code",
        stagesDone: ["plan", "design"],
        elapsed_s: 300,
        iteration: 3,
        maxIterations: 20,
      },
    ];
    pipelinesView.render(data);
    const tbody = document.getElementById("pipeline-table-body");
    expect(tbody).toBeTruthy();
    expect(tbody!.innerHTML).toContain("#100");
    expect(tbody!.innerHTML).toContain("Add feature X");
    expect(tbody!.innerHTML).toContain("ACTIVE");
  });

  it("renders empty state when no pipelines", async () => {
    const { pipelinesView } = await import("./pipelines");
    pipelinesView.init();
    const data = emptyFleetState();
    pipelinesView.render(data);
    const tbody = document.getElementById("pipeline-table-body");
    expect(tbody).toBeTruthy();
    expect(tbody!.innerHTML).toContain("No pipelines match filter");
  });

  it("handles various pipeline statuses from events", async () => {
    const { pipelinesView } = await import("./pipelines");
    pipelinesView.init();
    const data = emptyFleetState();
    data.pipelines = [];
    data.events = [
      {
        type: "pipeline.completed",
        issue: 50,
        issueTitle: "Done",
        duration_s: 600,
      },
      {
        type: "pipeline.failed",
        issue: 51,
        issueTitle: "Failed",
        duration_s: 120,
      },
    ];
    pipelinesView.render(data);
    const tbody = document.getElementById("pipeline-table-body");
    expect(tbody!.innerHTML).toContain("#50");
    expect(tbody!.innerHTML).toContain("#51");
    expect(tbody!.innerHTML).toContain("COMPLETED");
    expect(tbody!.innerHTML).toContain("FAILED");
  });

  it("filters by status when pipelineFilter is set", async () => {
    const { pipelinesView } = await import("./pipelines");
    store.set("pipelineFilter", "active");
    pipelinesView.init();
    const data = emptyFleetState();
    data.pipelines = [
      {
        issue: 1,
        title: "Active",
        stage: "code",
        stagesDone: [],
        elapsed_s: 60,
        iteration: 1,
        maxIterations: 20,
      },
    ];
    data.events = [
      { type: "pipeline.completed", issue: 2, issueTitle: "Done" },
    ];
    pipelinesView.render(data);
    const tbody = document.getElementById("pipeline-table-body");
    expect(tbody!.innerHTML).toContain("#1");
    expect(tbody!.innerHTML).not.toContain("#2");
  });
});
