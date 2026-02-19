import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { store } from "../core/state";
import type { FleetState, MetricsData } from "../types/api";

vi.mock("../core/api", () => ({
  fetchMetricsHistory: vi.fn().mockResolvedValue({
    success_rate: 0.95,
    avg_duration_s: 600,
    throughput_per_hour: 2.5,
    total_completed: 100,
    total_failed: 5,
    stage_durations: {},
    daily_counts: [],
  }),
  fetchCostBreakdown: vi.fn().mockResolvedValue({}),
  fetchCostTrend: vi.fn().mockResolvedValue({ points: [] }),
  fetchDoraTrend: vi.fn().mockResolvedValue({}),
  fetchStagePerformance: vi.fn().mockResolvedValue({ stages: [] }),
  fetchBottlenecks: vi.fn().mockResolvedValue({ bottlenecks: [] }),
  fetchThroughputTrend: vi.fn().mockResolvedValue({ points: [] }),
  fetchCapacity: vi.fn().mockResolvedValue({ rate: 1, queue_clear_hours: 2 }),
}));

function createMetricsDOM(): void {
  const ids = [
    "metric-donut-wrap",
    "metric-avg-duration",
    "metric-throughput",
    "metric-total-completed",
    "metric-total-failed",
    "stage-breakdown",
    "daily-chart",
    "dora-grades-container",
  ];
  for (const id of ids) {
    const el = document.createElement("div");
    el.id = id;
    document.body.appendChild(el);
  }
}

function cleanupMetricsDOM(): void {
  const ids = [
    "metric-donut-wrap",
    "metric-avg-duration",
    "metric-throughput",
    "metric-total-completed",
    "metric-total-failed",
    "stage-breakdown",
    "daily-chart",
    "dora-grades-container",
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

describe("MetricsView", () => {
  beforeEach(() => {
    store.set("firstRender", false);
    store.set("metricsCache", null);
    createMetricsDOM();
  });

  afterEach(() => {
    cleanupMetricsDOM();
    vi.clearAllMocks();
  });

  it("renders metric cards with cached data", async () => {
    const { metricsView } = await import("./metrics");
    const metricsData: MetricsData = {
      success_rate: 0.92,
      avg_duration_s: 420,
      throughput_per_hour: 3.5,
      total_completed: 50,
      total_failed: 4,
      stage_durations: { plan: 60, code: 300, review: 120 },
      daily_counts: [{ date: "2025-02-17", completed: 5, failed: 1 }],
      dora_grades: {} as any,
    };
    store.set("metricsCache", metricsData);
    const data = emptyFleetState();
    metricsView.render(data);
    const avgEl = document.getElementById("metric-avg-duration");
    const tpEl = document.getElementById("metric-throughput");
    const tcEl = document.getElementById("metric-total-completed");
    expect(avgEl?.textContent).toBeTruthy();
    expect(tpEl?.textContent).toBe("3.50");
    expect(tcEl?.textContent).toContain("50");
  });

  it("handles missing data gracefully", async () => {
    const { metricsView } = await import("./metrics");
    const emptyMetrics: MetricsData = {
      success_rate: 0,
      avg_duration_s: 0,
      throughput_per_hour: 0,
      total_completed: 0,
      total_failed: 0,
      stage_durations: {},
      daily_counts: [],
      dora_grades: {} as any,
    };
    store.set("metricsCache", emptyMetrics);
    const data = emptyFleetState();
    expect(() => metricsView.render(data)).not.toThrow();
    const donutEl = document.getElementById("metric-donut-wrap");
    expect(donutEl?.innerHTML).toBeTruthy();
  });

  it("formats numbers correctly for totals", async () => {
    const { metricsView } = await import("./metrics");
    const metricsData: MetricsData = {
      success_rate: 1,
      avg_duration_s: 0,
      throughput_per_hour: 0,
      total_completed: 1234,
      total_failed: 10,
      stage_durations: {},
      daily_counts: [],
      dora_grades: {} as any,
    };
    store.set("metricsCache", metricsData);
    const data = emptyFleetState();
    metricsView.render(data);
    const tcEl = document.getElementById("metric-total-completed");
    const failedEl = document.getElementById("metric-total-failed");
    expect(tcEl?.textContent).toContain("1,234");
    expect(failedEl?.textContent).toContain("10");
  });

  it("renders stage breakdown when stage_durations provided", async () => {
    const { metricsView } = await import("./metrics");
    const metricsData: MetricsData = {
      success_rate: 0,
      avg_duration_s: 0,
      throughput_per_hour: 0,
      total_completed: 0,
      total_failed: 0,
      stage_durations: { plan: 120, code: 400 },
      daily_counts: [],
      dora_grades: {} as any,
    };
    store.set("metricsCache", metricsData);
    const data = emptyFleetState();
    metricsView.render(data);
    const breakdownEl = document.getElementById("stage-breakdown");
    expect(breakdownEl?.innerHTML).toContain("plan");
    expect(breakdownEl?.innerHTML).toContain("code");
  });

  it("shows empty state when no metrics cache", async () => {
    const { metricsView } = await import("./metrics");
    store.set("metricsCache", null);
    const data = emptyFleetState();
    metricsView.render(data);
    expect(() => metricsView.render(data)).not.toThrow();
  });

  it("init and destroy do not throw", async () => {
    const { metricsView } = await import("./metrics");
    expect(() => metricsView.init()).not.toThrow();
    expect(() => metricsView.destroy()).not.toThrow();
  });
});
