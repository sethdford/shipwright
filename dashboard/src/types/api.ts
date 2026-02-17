// Shared TypeScript interfaces for all API responses
// These types mirror the actual shapes returned by dashboard/server.ts

export interface DaemonInfo {
  running: boolean;
  pid: number | null;
  uptime_s: number;
  maxParallel: number;
  pollInterval: number;
}

export interface PipelineInfo {
  issue: number;
  title: string;
  stage: string;
  stagesDone: string[];
  elapsed_s: number;
  worktree?: string;
  iteration: number;
  maxIterations: number;
  linesWritten?: number;
  testsPassing?: boolean;
  cost?: number;
  branch?: string;
  status?: string;
}

export interface QueueItem {
  issue: number;
  title: string;
  score?: number;
  estimated_cost?: number;
  factors?: ScoringFactors;
}

export interface ScoringFactors {
  complexity?: number;
  impact?: number;
  priority?: number;
  age?: number;
  dependency?: number;
  memory?: number;
}

export interface EventItem {
  ts?: string;
  timestamp?: string;
  type: string;
  issue?: number;
  issueTitle?: string;
  title?: string;
  duration_s?: number;
  stage?: string;
  result?: string;
  [key: string]: unknown;
}

export interface ScaleInfo {
  from?: number;
  to?: number;
  cpuCores?: number;
  maxByCpu?: number;
  maxByMem?: number;
  maxByBudget?: number;
  availMemGb?: number;
}

export interface MetricsSummary {
  completed?: number;
  failed?: number;
  cpuCores?: number;
}

export interface CostInfo {
  today_spent: number;
  daily_budget: number;
  pct_used: number;
}

export interface DoraMetric {
  value: number;
  unit: string;
  grade: string;
}

export interface DoraGrades {
  deploy_freq: DoraMetric;
  lead_time: DoraMetric;
  cfr: DoraMetric;
  mttr: DoraMetric;
}

export interface AgentInfo {
  id: string;
  issue: number;
  title: string;
  machine: string;
  stage: string;
  iteration: number;
  activity: string;
  memory_mb: number;
  cpu_pct: number;
  status: "active" | "idle" | "stale" | "dead";
  heartbeat_age_s: number;
  started_at: string;
  elapsed_s: number;
}

export interface FleetState {
  timestamp: string;
  daemon: DaemonInfo;
  pipelines: PipelineInfo[];
  queue: QueueItem[];
  events: EventItem[];
  scale: ScaleInfo;
  metrics: MetricsSummary;
  agents: AgentInfo[];
  machines: MachineInfo[];
  cost: CostInfo;
  dora: DoraGrades;
  team?: TeamData;
}

export interface CostBreakdown {
  by_model?: Record<string, number>;
  by_stage?: Record<string, number>;
  by_issue?: Array<{ issue: number; cost: number }>;
  budget?: number;
  spent?: number;
}

export interface StageHistoryEntry {
  stage: string;
  duration_s: number;
  ts: string;
}

export interface PipelineDetail {
  issue: number;
  title: string;
  stage: string;
  stageHistory: StageHistoryEntry[];
  plan: string;
  design: string;
  dod: string;
  intake: Record<string, unknown> | null;
  elapsed_s: number;
  branch: string;
  prLink: string;
}

export interface TimelineEntry {
  issue: number;
  title: string;
  segments: TimelineSegment[];
}

export interface TimelineSegment {
  stage: string;
  start: string;
  end: string | null;
  status: "complete" | "running" | "failed";
}

export interface MetricsData {
  success_rate: number;
  avg_duration_s: number;
  throughput_per_hour: number;
  total_completed: number;
  total_failed: number;
  stage_durations: Record<string, number>;
  daily_counts: DailyCount[];
  dora_grades: DoraGrades;
}

export interface DailyCount {
  date: string;
  completed: number;
  failed: number;
}

export interface DoraMetrics {
  deploy_freq?: DoraMetric;
  lead_time?: DoraMetric;
  cfr?: DoraMetric;
  mttr?: DoraMetric;
}

export interface MachineInfo {
  name: string;
  host: string;
  role: string;
  max_workers: number;
  active_workers: number;
  registered_at: string;
  ssh_user?: string;
  shipwright_path?: string;
  status: "online" | "degraded" | "offline";
  health: MachineHealth;
  join_token?: string;
}

export interface MachineHealth {
  daemon_running: boolean;
  heartbeat_count: number;
  last_heartbeat_s_ago: number;
}

export interface JoinToken {
  label: string;
  created_at?: string;
  used?: boolean;
  token?: string;
}

export interface InsightsData {
  patterns: FailurePattern[] | null;
  decisions: Decision[] | null;
  patrol: PatrolFinding[] | null;
  heatmap: HeatmapData | null;
  globalLearnings: Array<Record<string, unknown>> | null;
}

export interface FailurePattern {
  description?: string;
  pattern?: string;
  frequency?: number;
  count?: number;
  root_cause?: string;
  fix?: string;
  suggested_fix?: string;
}

export interface Decision {
  timestamp?: string;
  ts?: string;
  action?: string;
  decision?: string;
  outcome?: string;
  result?: string;
  issue?: number;
}

export interface PatrolFinding {
  severity?: string;
  type?: string;
  category?: string;
  description?: string;
  message?: string;
  file?: string;
}

// Heatmap from server: { heatmap: Record<stage, Record<date, count>> }
export interface HeatmapData {
  heatmap: Record<string, Record<string, number>>;
}

export interface DaemonConfig {
  paused?: boolean;
  config?: Record<string, unknown>;
  budget?: Record<string, unknown>;
}

export interface AlertInfo {
  severity: string;
  message: string;
  type?: string;
  issue?: number;
  actions?: string[];
}

export interface TeamData {
  total_online?: number;
  total_active_pipelines?: number;
  total_queued?: number;
  developers?: TeamDeveloper[];
}

export interface TeamDeveloper {
  developer_id: string;
  machine_name: string;
  hostname?: string;
  platform?: string;
  last_heartbeat?: number;
  daemon_running: boolean;
  daemon_pid?: number | null;
  active_jobs: Array<{ issue: number; title?: string; stage?: string }>;
  queued: number[];
  events_since?: number;
  _presence?: string;
}

export interface TeamActivityEvent {
  ts?: string;
  type: string;
  issue?: number;
  from_developer?: string;
  stage?: string;
  result?: string;
}

export interface StagePerformance {
  name?: string;
  stage?: string;
  avg_s: number;
  min_s?: number;
  max_s?: number;
  count: number;
  trend_pct?: number;
}

export interface UserInfo {
  username?: string;
  avatarUrl?: string;
  isAdmin?: boolean;
  role?: "viewer" | "operator" | "admin";
}

export type TabId =
  | "overview"
  | "agents"
  | "pipelines"
  | "timeline"
  | "activity"
  | "metrics"
  | "machines"
  | "insights"
  | "team"
  | "fleet-map"
  | "pipeline-theater"
  | "agent-cockpit";

export interface View {
  init(): void;
  render(state: FleetState): void;
  destroy(): void;
}
