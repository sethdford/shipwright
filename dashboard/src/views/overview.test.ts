import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { store } from "../core/state";
import type { FleetState } from "../types/api";

vi.mock("../core/api", () => ({
  fetchQueueDetailed: vi.fn().mockResolvedValue({ items: [] }),
}));

vi.mock("./pipelines", () => ({
  fetchPipelineDetail: vi.fn(),
}));

vi.mock("../components/header", () => ({
  renderCostTicker: vi.fn(),
}));

function createOverviewDOM(): void {
  const ids = [
    "stat-status",
    "status-dot",
    "stat-active",
    "stat-active-bar",
    "stat-queue",
    "stat-queue-sub",
    "stat-completed",
    "stat-failed-sub",
    "active-pipelines",
    "queue-list",
    "activity-feed",
    "res-cpu-bar",
    "res-cpu-info",
    "res-mem-bar",
    "res-mem-info",
    "res-budget-bar",
    "res-budget-info",
    "resource-constraint",
    "machines-section",
    "machines-grid",
  ];
  for (const id of ids) {
    if (!document.getElementById(id)) {
      const el = document.createElement("div");
      el.id = id;
      document.body.appendChild(el);
    }
  }
}

function cleanupOverviewDOM(): void {
  const ids = [
    "stat-status",
    "status-dot",
    "stat-active",
    "stat-active-bar",
    "stat-queue",
    "stat-queue-sub",
    "stat-completed",
    "stat-failed-sub",
    "active-pipelines",
    "queue-list",
    "activity-feed",
    "res-cpu-bar",
    "res-cpu-info",
    "res-mem-bar",
    "res-mem-info",
    "res-budget-bar",
    "res-budget-info",
    "resource-constraint",
    "machines-section",
    "machines-grid",
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

describe("OverviewView", () => {
  beforeEach(() => {
    store.set("firstRender", false);
    createOverviewDOM();
  });

  afterEach(() => {
    cleanupOverviewDOM();
    vi.clearAllMocks();
  });

  it("renders without crashing when given empty data", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    expect(() => overviewView.render(data)).not.toThrow();
  });

  it("renders pipeline summary section with empty pipelines", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    overviewView.render(data);
    const container = document.getElementById("active-pipelines");
    expect(container).toBeTruthy();
    expect(container!.innerHTML).toContain("No active pipelines");
  });

  it("renders pipeline cards when pipelines exist", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    data.pipelines = [
      {
        issue: 42,
        title: "Fix bug",
        stage: "code",
        stagesDone: ["plan"],
        elapsed_s: 120,
        iteration: 2,
        maxIterations: 20,
      },
    ];
    overviewView.render(data);
    const container = document.getElementById("active-pipelines");
    expect(container).toBeTruthy();
    expect(container!.innerHTML).toContain("#42");
    expect(container!.innerHTML).toContain("Fix bug");
    expect(container!.innerHTML).toContain("pipeline-card");
  });

  it("handles null/undefined state gracefully", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    (data as any).pipelines = null;
    (data as any).queue = undefined;
    (data as any).events = undefined;
    expect(() => overviewView.render(data)).not.toThrow();
    const pipelinesEl = document.getElementById("active-pipelines");
    expect(pipelinesEl!.innerHTML).toContain("No active pipelines");
  });

  it("renders queue empty state", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    overviewView.render(data);
    const queueEl = document.getElementById("queue-list");
    expect(queueEl).toBeTruthy();
    expect(queueEl!.innerHTML).toContain("Queue clear");
  });

  it("renders activity empty state", async () => {
    const { overviewView } = await import("./overview");
    const data = emptyFleetState();
    overviewView.render(data);
    const activityEl = document.getElementById("activity-feed");
    expect(activityEl).toBeTruthy();
    expect(activityEl!.innerHTML).toContain("Awaiting events");
  });
});
