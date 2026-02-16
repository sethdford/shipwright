// Global state store with typed subscriptions

import type {
  FleetState,
  TabId,
  PipelineDetail,
  InsightsData,
  MetricsData,
  MachineInfo,
  JoinToken,
  DaemonConfig,
  AlertInfo,
  TeamData,
  TeamActivityEvent,
  UserInfo,
} from "../types/api";

export interface AppState {
  connected: boolean;
  connectedAt: number | null;
  fleetState: FleetState | null;
  activeTab: TabId;
  selectedPipelineIssue: number | null;
  pipelineDetail: PipelineDetail | null;
  pipelineFilter: string;
  activityFilter: string;
  activityIssueFilter: string;
  activityEvents: Array<Record<string, unknown>>;
  activityOffset: number;
  activityHasMore: boolean;
  metricsCache: MetricsData | null;
  insightsCache: InsightsData | null;
  machinesCache: MachineInfo[] | null;
  joinTokensCache: JoinToken[] | null;
  costBreakdownCache: Record<string, unknown> | null;
  alertsCache: AlertInfo[] | null;
  alertDismissed: boolean;
  teamCache: TeamData | null;
  teamActivityCache: TeamActivityEvent[] | null;
  daemonConfig: DaemonConfig | null;
  currentUser: UserInfo | null;
  selectedIssues: Record<string, boolean>;
  firstRender: boolean;
}

const initialState: AppState = {
  connected: false,
  connectedAt: null,
  fleetState: null,
  activeTab: "overview",
  selectedPipelineIssue: null,
  pipelineDetail: null,
  pipelineFilter: "all",
  activityFilter: "all",
  activityIssueFilter: "",
  activityEvents: [],
  activityOffset: 0,
  activityHasMore: false,
  metricsCache: null,
  insightsCache: null,
  machinesCache: null,
  joinTokensCache: null,
  costBreakdownCache: null,
  alertsCache: null,
  alertDismissed: false,
  teamCache: null,
  teamActivityCache: null,
  daemonConfig: null,
  currentUser: null,
  selectedIssues: {},
  firstRender: true,
};

type Listener<K extends keyof AppState> = (
  value: AppState[K],
  prev: AppState[K],
) => void;
type AnyListener = (state: AppState) => void;

class Store {
  private state: AppState;
  private listeners: Map<keyof AppState, Set<Listener<any>>> = new Map();
  private globalListeners: Set<AnyListener> = new Set();

  constructor() {
    this.state = { ...initialState };
  }

  get<K extends keyof AppState>(key: K): AppState[K] {
    return this.state[key];
  }

  getState(): Readonly<AppState> {
    return this.state;
  }

  set<K extends keyof AppState>(key: K, value: AppState[K]): void {
    const prev = this.state[key];
    if (prev === value) return;
    this.state = { ...this.state, [key]: value };
    const keyListeners = this.listeners.get(key);
    if (keyListeners) {
      keyListeners.forEach((fn) => fn(value, prev));
    }
    this.globalListeners.forEach((fn) => fn(this.state));
  }

  update(partial: Partial<AppState>): void {
    const keys = Object.keys(partial) as Array<keyof AppState>;
    let changed = false;
    const prevState = this.state;
    const nextState = { ...this.state };
    for (const key of keys) {
      if (nextState[key] !== partial[key]) {
        (nextState as any)[key] = partial[key];
        changed = true;
      }
    }
    if (!changed) return;
    this.state = nextState;
    for (const key of keys) {
      if (prevState[key] !== this.state[key]) {
        const keyListeners = this.listeners.get(key);
        if (keyListeners) {
          keyListeners.forEach((fn) => fn(this.state[key], prevState[key]));
        }
      }
    }
    this.globalListeners.forEach((fn) => fn(this.state));
  }

  subscribe<K extends keyof AppState>(key: K, fn: Listener<K>): () => void {
    if (!this.listeners.has(key)) {
      this.listeners.set(key, new Set());
    }
    this.listeners.get(key)!.add(fn);
    return () => {
      this.listeners.get(key)?.delete(fn);
    };
  }

  onAny(fn: AnyListener): () => void {
    this.globalListeners.add(fn);
    return () => {
      this.globalListeners.delete(fn);
    };
  }
}

export const store = new Store();
