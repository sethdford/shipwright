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
  HeatmapData,
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

// Timeline — server returns bare array
export const fetchTimeline = (range = "24h") =>
  request<TimelineEntry[]>(`/api/timeline?range=${range}`);

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

// Machines — server returns bare array
export const fetchMachines = () => request<MachineInfo[]>("/api/machines");
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
  request<HeatmapData>("/api/metrics/failure-heatmap").catch(() => null);

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
  request<{
    bottlenecks: Array<{
      stage: string;
      avgDuration: number;
      impact: string;
      suggestion: string;
    }>;
  }>("/api/metrics/bottlenecks");
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
  request<{ queue: Array<Record<string, unknown>> }>(
    "/api/queue/detailed",
  ).then((d) => ({ items: d.queue || [] }));

// Team
export const fetchTeam = () => request<TeamData>("/api/team");
export const fetchTeamActivity = () =>
  request<{ events: TeamActivityEvent[] }>("/api/team/activity")
    .then((d) => d.events)
    .catch(() => [] as TeamActivityEvent[]);

// Pipeline live changes
export const fetchPipelineDiff = (issue: number | string) =>
  request<{
    diff: string;
    stats: { files_changed: number; insertions: number; deletions: number };
    worktree: string;
  }>(`/api/pipeline/${encodeURIComponent(issue)}/diff`);

export const fetchPipelineFiles = (issue: number | string) =>
  request<{ files: Array<{ path: string; status: string }> }>(
    `/api/pipeline/${encodeURIComponent(issue)}/files`,
  );

export const fetchPipelineTestResults = (issue: number | string) =>
  request<Record<string, unknown>>(
    `/api/pipeline/${encodeURIComponent(issue)}/test-results`,
  );

// Pipeline reasoning and failures
export const fetchPipelineReasoning = (issue: number | string) =>
  request<{ reasoning: Array<Record<string, unknown>> }>(
    `/api/pipeline/${encodeURIComponent(issue)}/reasoning`,
  );

export const fetchPipelineFailures = (issue: number | string) =>
  request<{ failures: Array<Record<string, unknown>> }>(
    `/api/pipeline/${encodeURIComponent(issue)}/failures`,
  );

// Global learnings
export const fetchGlobalLearnings = () =>
  request<{ learnings: Array<Record<string, unknown>> }>("/api/memory/global");

// Team invites
export const createTeamInvite = (options?: {
  expires_hours?: number;
  max_uses?: number;
}) =>
  request<{ token: string; url: string; expires_at: string }>(
    "/api/team/invite",
    { method: "POST", body: JSON.stringify(options || {}) },
  );

// Linear integration status
export const fetchLinearStatus = () =>
  request<Record<string, unknown>>("/api/linear/status");

// DB debug endpoints
export const fetchDbEvents = (since = 0, limit = 200) =>
  request<{ events: Array<Record<string, unknown>>; source: string }>(
    `/api/db/events?since=${since}&limit=${limit}`,
  );

export const fetchDbJobs = (status?: string) =>
  request<{ jobs: Array<Record<string, unknown>>; source: string }>(
    `/api/db/jobs${status ? `?status=${status}` : ""}`,
  );

export const fetchDbCostsToday = () =>
  request<Record<string, unknown>>("/api/db/costs/today");

export const fetchDbHeartbeats = () =>
  request<{ heartbeats: Array<Record<string, unknown>>; source: string }>(
    "/api/db/heartbeats",
  );

export const fetchDbHealth = () =>
  request<Record<string, unknown>>("/api/db/health");

// Machine claim/release
export const claimIssue = (issue: number, machine: string, repo?: string) =>
  request<{ approved: boolean; claimed_by?: string; error?: string }>(
    "/api/claim",
    {
      method: "POST",
      body: JSON.stringify({ issue, machine, repo }),
    },
  );

export const releaseIssue = (issue: number, machine?: string, repo?: string) =>
  request<{ ok: boolean }>("/api/claim/release", {
    method: "POST",
    body: JSON.stringify({ issue, machine, repo }),
  });

// Audit log
export const fetchAuditLog = () =>
  request<{ entries: Array<Record<string, unknown>> }>("/api/audit-log");

// Quality gates
export const fetchQualityGates = () =>
  request<{
    enabled: boolean;
    rules: Array<{
      name: string;
      operator: string;
      threshold: number;
      unit: string;
    }>;
  }>("/api/quality-gates");

export const fetchPipelineQuality = (issue: number | string) =>
  request<{
    quality: Record<string, unknown>;
    gates: Record<string, unknown>;
    results: Array<{
      name: string;
      operator: string;
      threshold: number;
      value: unknown;
      passed: boolean;
    }>;
  }>(`/api/pipeline/${encodeURIComponent(issue)}/quality`);

// Approval gates
export const fetchApprovalGates = () =>
  request<{
    enabled: boolean;
    stages: string[];
    pending: Array<{ issue: number; stage: string; requested_at: string }>;
  }>("/api/approval-gates");

export const updateApprovalGates = (config: {
  enabled?: boolean;
  stages?: string[];
}) =>
  request<{ ok: boolean }>("/api/approval-gates", {
    method: "POST",
    body: JSON.stringify(config),
  });

export const approveGate = (issue: number, stage?: string) =>
  request<{ ok: boolean }>(`/api/approval-gates/${issue}/approve`, {
    method: "POST",
    body: JSON.stringify({ stage }),
  });

export const rejectGate = (issue: number, stage?: string, reason?: string) =>
  request<{ ok: boolean }>(`/api/approval-gates/${issue}/reject`, {
    method: "POST",
    body: JSON.stringify({ stage, reason }),
  });

// Notifications
export const fetchNotificationConfig = () =>
  request<{
    enabled: boolean;
    webhooks: Array<{
      url: string;
      label: string;
      events: string[];
      created_at: string;
    }>;
  }>("/api/notifications/config");

export const addWebhook = (url: string, label?: string, events?: string[]) =>
  request<{ ok: boolean }>("/api/notifications/webhook", {
    method: "POST",
    body: JSON.stringify({ url, label, events }),
  });

export const removeWebhook = (url: string) =>
  request<{ ok: boolean }>("/api/notifications/webhook", {
    method: "DELETE",
    body: JSON.stringify({ url }),
  });

export const testNotification = () =>
  request<{ ok: boolean }>("/api/notifications/test", { method: "POST" });

// Predictions (new endpoint, returns graceful defaults if not yet implemented)
export const fetchPredictions = (issue: number | string) =>
  request<{
    eta_s?: number;
    success_probability?: number;
    estimated_cost?: number;
  }>(`/api/predictions/${encodeURIComponent(issue)}`).catch(() => ({}));
