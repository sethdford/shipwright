// Shared TypeScript interfaces for all API responses

export interface DaemonInfo {
  running: boolean;
  maxParallel: number;
  watchLabel?: string;
  paused?: boolean;
}

export interface PipelineInfo {
  issue: number;
  title: string;
  stage: string;
  stagesDone: string[];
  status: string;
  elapsed_s: number;
  iteration: number;
  maxIterations: number;
  linesWritten?: number;
  testsPassing?: boolean | null;
  worktree?: string;
  cost?: number;
  branch?: string;
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

export interface FleetState {
  daemon: DaemonInfo;
  pipelines: PipelineInfo[];
  queue: QueueItem[];
  events: EventItem[];
  scale: ScaleInfo;
  metrics: MetricsSummary;
  agents?: AgentInfo[];
  cost?: CostInfo;
  team?: TeamData;
}

export interface AgentInfo {
  issue: number;
  title?: string;
  stage: string;
  status: string;
  elapsed_s?: number;
  cpu?: number;
  memory?: number;
  pid?: number;
  worktree?: string;
  lastActivity?: string;
  selfHealing?: boolean;
  iteration?: number;
  maxIterations?: number;
}

export interface CostInfo {
  total_24h?: number;
  budget_remaining?: number;
  daily_limit?: number;
  burn_rate?: number;
}

export interface CostBreakdown {
  by_model?: Record<string, number>;
  by_stage?: Record<string, number>;
  by_issue?: Array<{ issue: number; cost: number }>;
  budget?: number;
  spent?: number;
}

export interface PipelineDetail {
  issue: number;
  title: string;
  stage: string;
  stagesDone: string[];
  status: string;
  elapsed_s: number;
  iteration: number;
  maxIterations: number;
  plan?: string;
  design?: string;
  dod?: string;
  worktree?: string;
  branch?: string;
  cost?: number;
  linesWritten?: number;
  testsPassing?: boolean | null;
  stages?: StageDetail[];
}

export interface StageDetail {
  name: string;
  status: string;
  duration_s?: number;
  started_at?: string;
  completed_at?: string;
}

export interface TimelineEntry {
  issue: number;
  title?: string;
  start: string;
  end?: string;
  stages: TimelineStage[];
  status: string;
}

export interface TimelineStage {
  name: string;
  start: string;
  end?: string;
  status: string;
}

export interface MetricsData {
  success_rate: number;
  avg_duration_s: number;
  total_completed: number;
  total_failed: number;
  daily_counts: DailyCount[];
  stage_breakdown: StageBreakdownItem[];
  dora?: DoraMetrics;
}

export interface DailyCount {
  date: string;
  completed: number;
  failed: number;
}

export interface StageBreakdownItem {
  stage: string;
  avg_s: number;
  count: number;
}

export interface DoraMetrics {
  deploy_freq?: DoraMetric;
  lead_time?: DoraMetric;
  cfr?: DoraMetric;
  mttr?: DoraMetric;
}

export interface DoraMetric {
  grade: string;
  value: number;
  unit: string;
}

export interface MachineInfo {
  name: string;
  host: string;
  role: string;
  status: string;
  max_workers: number;
  active_workers: number;
  health: MachineHealth;
}

export interface MachineHealth {
  daemon_running?: boolean;
  heartbeat_count?: number;
  last_heartbeat_s_ago?: number;
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

export interface HeatmapData {
  stages: string[];
  days: string[];
  cells: Record<string, number>;
}

export interface DaemonConfig {
  paused?: boolean;
  config?: {
    watch_label?: string;
    max_workers?: number;
    poll_interval?: number;
    patrol?: { interval?: number };
  };
  budget?: {
    remaining?: number;
    daily_limit?: number;
  };
}

export interface AlertInfo {
  severity: string;
  message: string;
  type?: string;
  issue?: number;
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
  daemon_running: boolean;
  active_jobs: Array<{ issue: number; stage?: string }>;
  queued: Array<{ issue: number }>;
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
  name?: string;
  username?: string;
  avatar_url?: string;
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
