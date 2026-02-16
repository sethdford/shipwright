// Typed REST client for all dashboard API endpoints

import type {
  PipelineDetail,
  MetricsData,
  TimelineEntry,
  MachineInfo,
  JoinToken,
  CostBreakdown,
  DaemonConfig,
  AlertInfo,
  InsightsData,
  TeamData,
  TeamActivityEvent,
  StagePerformance,
  UserInfo,
} from "../types/api";

async function request<T>(url: string, options?: RequestInit): Promise<T> {
  const resp = await fetch(url, options);
  if (!resp.ok) {
    const body = await resp
      .json()
      .catch(() => ({ error: `HTTP ${resp.status}` }));
    throw new Error(body.error || `HTTP ${resp.status}`);
  }
  return resp.json();
}

function post<T>(url: string, body?: unknown): Promise<T> {
  const opts: RequestInit = {
    method: "POST",
    headers: { "Content-Type": "application/json" },
  };
  if (body !== undefined) opts.body = JSON.stringify(body);
  return request<T>(url, opts);
}

function patch<T>(url: string, body: unknown): Promise<T> {
  return request<T>(url, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function del<T>(url: string): Promise<T> {
  return request<T>(url, {
    method: "DELETE",
    headers: { "Content-Type": "application/json" },
  });
}

// User
export const fetchMe = () => request<UserInfo>("/api/me");

// Pipeline detail
export const fetchPipelineDetail = (issue: number | string) =>
  request<PipelineDetail>(`/api/pipeline/${encodeURIComponent(issue)}`);

// Metrics
export const fetchMetricsHistory = (period = 30) =>
  request<MetricsData>(`/api/metrics/history?period=${period}`);

// Timeline
export const fetchTimeline = (range = "24h") =>
  request<{ entries: TimelineEntry[] }>(`/api/timeline?range=${range}`);

// Activity
export const fetchActivity = (params: {
  limit?: number;
  offset?: number;
  type?: string;
  issue?: string;
}) => {
  const qs = new URLSearchParams();
  if (params.limit) qs.set("limit", String(params.limit));
  if (params.offset) qs.set("offset", String(params.offset));
  if (params.type && params.type !== "all") qs.set("type", params.type);
  if (params.issue) qs.set("issue", params.issue);
  return request<{ events: Array<Record<string, unknown>>; hasMore: boolean }>(
    `/api/activity?${qs}`,
  );
};

// Machines
export const fetchMachines = () =>
  request<{ machines: MachineInfo[] }>("/api/machines");
export const addMachine = (body: Record<string, unknown>) =>
  post<MachineInfo>("/api/machines", body);
export const updateMachine = (name: string, body: Record<string, unknown>) =>
  patch<MachineInfo>(`/api/machines/${encodeURIComponent(name)}`, body);
export const removeMachine = (name: string) =>
  del<{ ok: boolean }>(`/api/machines/${encodeURIComponent(name)}`);
export const machineHealthCheck = (name: string) =>
  post<{ machine: MachineInfo }>(
    `/api/machines/${encodeURIComponent(name)}/health-check`,
  );

// Join tokens
export const fetchJoinTokens = () =>
  request<{ tokens: JoinToken[] }>("/api/join-token");
export const generateJoinToken = (body: {
  label: string;
  max_workers: number;
}) => post<{ join_cmd: string }>("/api/join-token", body);

// Costs
export const fetchCostBreakdown = (period = 7) =>
  request<CostBreakdown>(`/api/costs/breakdown?period=${period}`);
export const fetchCostTrend = (period = 30) =>
  request<{ points: Array<Record<string, number>> }>(
    `/api/costs/trend?period=${period}`,
  );

// Daemon
export const fetchDaemonConfig = () =>
  request<DaemonConfig>("/api/daemon/config");
export const daemonControl = (action: string) =>
  post<{ ok: boolean }>(`/api/daemon/${action}`);

// Alerts
export const fetchAlerts = () =>
  request<{ alerts: AlertInfo[] }>("/api/alerts");

// Emergency brake
export const emergencyBrake = () =>
  post<{ ok: boolean }>("/api/emergency-brake");

// Intervention
export const sendIntervention = (
  issue: number | string,
  action: string,
  body?: unknown,
) => post<{ ok: boolean }>(`/api/intervention/${issue}/${action}`, body);

// Insights
export const fetchPatterns = () =>
  request<{ patterns: InsightsData["patterns"] }>("/api/memory/patterns").catch(
    () => ({ patterns: [] }),
  );
export const fetchDecisions = () =>
  request<{ decisions: InsightsData["decisions"] }>(
    "/api/memory/decisions",
  ).catch(() => ({ decisions: [] }));
export const fetchPatrol = () =>
  request<{ findings: InsightsData["patrol"] }>("/api/patrol/recent").catch(
    () => ({ findings: [] }),
  );
export const fetchHeatmap = () =>
  request<InsightsData["heatmap"]>("/api/metrics/failure-heatmap").catch(
    () => null,
  );

// Artifacts
export const fetchArtifact = (issue: number | string, type: string) =>
  request<{ content: string }>(
    `/api/artifacts/${encodeURIComponent(issue)}/${encodeURIComponent(type)}`,
  );

// GitHub
export const fetchGitHubStatus = (issue: number | string) =>
  request<Record<string, unknown>>(`/api/github/${encodeURIComponent(issue)}`);

// Logs
export const fetchLogs = (issue: number | string) =>
  request<{ content: string }>(`/api/logs/${encodeURIComponent(issue)}`);

// Metrics detail
export const fetchStagePerformance = (period = 7) =>
  request<{ stages: StagePerformance[] }>(
    `/api/metrics/stage-performance?period=${period}`,
  );
export const fetchBottlenecks = () =>
  request<{ bottleneck: Record<string, unknown> | null }>(
    "/api/metrics/bottlenecks",
  );
export const fetchThroughputTrend = (period = 30) =>
  request<{ points: Array<Record<string, number>> }>(
    `/api/metrics/throughput-trend?period=${period}`,
  );
export const fetchCapacity = () =>
  request<{ rate: number; queue_clear_hours: number }>("/api/metrics/capacity");
export const fetchDoraTrend = (period = 30) =>
  request<Record<string, Array<Record<string, number>>>>(
    `/api/metrics/dora-trend?period=${period}`,
  );

// Queue detailed
export const fetchQueueDetailed = () =>
  request<{ items: Array<Record<string, unknown>> }>("/api/queue/detailed");

// Team
export const fetchTeam = () => request<TeamData>("/api/team");
export const fetchTeamActivity = () =>
  request<{ events: TeamActivityEvent[] }>("/api/team/activity")
    .then((d) => d.events)
    .catch(() => [] as TeamActivityEvent[]);

// Predictions (new endpoint, returns graceful defaults if not yet implemented)
export const fetchPredictions = (issue: number | string) =>
  request<{
    eta_s?: number;
    success_probability?: number;
    estimated_cost?: number;
  }>(`/api/predictions/${encodeURIComponent(issue)}`).catch(() => ({}));
