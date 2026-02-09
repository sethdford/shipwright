import {
  readFileSync,
  readdirSync,
  writeFileSync,
  renameSync,
  mkdirSync,
  existsSync,
  watch,
  type FSWatcher,
} from "fs";
import { join, extname } from "path";
import { execSync } from "child_process";

// ─── Config ──────────────────────────────────────────────────────────
const PORT = parseInt(
  process.argv[2] || process.env.SHIPWRIGHT_DASHBOARD_PORT || "8767",
);
const HOME = process.env.HOME || "";
const EVENTS_FILE = join(HOME, ".claude-teams", "events.jsonl");
const DAEMON_STATE = join(HOME, ".claude-teams", "daemon-state.json");
const LOGS_DIR = join(HOME, ".claude-teams", "logs");
const HEARTBEAT_DIR = join(HOME, ".claude-teams", "heartbeats");
const MACHINES_FILE = join(HOME, ".claude-teams", "machines.json");
const COSTS_FILE = join(HOME, ".shipwright", "costs.json");
const BUDGET_FILE = join(HOME, ".shipwright", "budget.json");
const PUBLIC_DIR = join(import.meta.dir, "public");
const WS_PUSH_INTERVAL_MS = 2000;

// ─── Auth Config ────────────────────────────────────────────────────
// Mode 1: Full OAuth — set GITHUB_CLIENT_ID + GITHUB_CLIENT_SECRET + DASHBOARD_REPO
const GITHUB_CLIENT_ID = process.env.GITHUB_CLIENT_ID || "";
const GITHUB_CLIENT_SECRET = process.env.GITHUB_CLIENT_SECRET || "";
// Mode 2: PAT-based — set GITHUB_PAT + DASHBOARD_REPO (simpler, single-admin)
const GITHUB_PAT = process.env.GITHUB_PAT || "";
const DASHBOARD_REPO = process.env.DASHBOARD_REPO || ""; // "owner/repo"
const SESSION_SECRET = process.env.SESSION_SECRET || crypto.randomUUID();
const SESSION_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours
const ALLOWED_PERMISSIONS = ["admin", "write"];

// ─── ANSI helpers ────────────────────────────────────────────────────
const CYAN = "\x1b[38;2;0;212;255m";
const GREEN = "\x1b[38;2;74;222;128m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const ULINE = "\x1b[4m";
const RESET = "\x1b[0m";

// ─── Types ───────────────────────────────────────────────────────────
interface DaemonEvent {
  ts: string;
  ts_epoch?: number;
  type: string;
  issue?: number;
  stage?: string;
  duration_s?: number;
  pid?: number;
  issues_found?: number;
  active?: number;
  from?: number;
  to?: number;
  max_by_cpu?: number;
  max_by_mem?: number;
  max_by_budget?: number;
  cpu_cores?: number;
  avail_mem_gb?: number;
  result?: string;
  [key: string]: unknown;
}

interface Pipeline {
  issue: number;
  title: string;
  stage: string;
  elapsed_s: number;
  worktree: string;
  iteration: number;
  maxIterations: number;
  stagesDone: string[];
  linesWritten: number;
  testsPassing: boolean;
}

interface QueueItem {
  issue: number;
  title: string;
  score: number;
}

interface FleetState {
  timestamp: string;
  daemon: {
    running: boolean;
    pid: number | null;
    uptime_s: number;
    maxParallel: number;
    pollInterval: number;
  };
  pipelines: Pipeline[];
  queue: QueueItem[];
  events: DaemonEvent[];
  scale: {
    from?: number;
    to?: number;
    maxByCpu?: number;
    maxByMem?: number;
    maxByBudget?: number;
    cpuCores?: number;
    availMemGb?: number;
  };
  metrics: {
    cpuCores: number;
    completed: number;
    failed: number;
  };
  agents: AgentInfo[];
  machines: MachineInfo[];
  cost: CostInfo;
}

interface HealthResponse {
  status: "ok";
  uptime_s: number;
  connections: number;
}

interface Session {
  githubUser: string;
  accessToken: string;
  avatarUrl: string;
  isAdmin: boolean;
  expiresAt: number;
}

// ─── Session Store ──────────────────────────────────────────────────
const sessions = new Map<string, Session>();

function createSession(data: Omit<Session, "expiresAt">): string {
  const sessionId = crypto.randomUUID();
  sessions.set(sessionId, {
    ...data,
    expiresAt: Date.now() + SESSION_TTL_MS,
  });
  return sessionId;
}

function getSession(req: Request): Session | null {
  const cookie = req.headers.get("cookie");
  if (!cookie) return null;

  const match = cookie.match(/fleet_session=([^;]+)/);
  if (!match) return null;

  const sessionId = match[1];
  const session = sessions.get(sessionId);
  if (!session) return null;

  if (Date.now() > session.expiresAt) {
    sessions.delete(sessionId);
    return null;
  }

  return session;
}

function getSessionFromCookie(cookie: string | null): Session | null {
  if (!cookie) return null;
  const match = cookie.match(/fleet_session=([^;]+)/);
  if (!match) return null;
  const session = sessions.get(match[1]);
  if (!session || Date.now() > session.expiresAt) return null;
  return session;
}

function sessionCookie(sessionId: string): string {
  return `fleet_session=${sessionId}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`;
}

function clearSessionCookie(): string {
  return "fleet_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0";
}

// ─── Auth check ─────────────────────────────────────────────────────
type AuthMode = "oauth" | "pat" | "none";

function getAuthMode(): AuthMode {
  if (GITHUB_CLIENT_ID && GITHUB_CLIENT_SECRET && DASHBOARD_REPO)
    return "oauth";
  if (GITHUB_PAT && DASHBOARD_REPO) return "pat";
  return "none";
}

function isAuthEnabled(): boolean {
  return getAuthMode() !== "none";
}

// ─── Public routes (no auth required) ───────────────────────────────
function isPublicRoute(pathname: string): boolean {
  return (
    pathname === "/login" ||
    pathname.startsWith("/auth/") ||
    pathname === "/api/health"
  );
}

// ─── Login Page HTML ────────────────────────────────────────────────
function loginPageHTML(error?: string): string {
  const mode = getAuthMode();

  const errorHtml = error
    ? `<p style="color:#f43f5e;margin-bottom:1.5rem;font-size:0.9rem;">${error}</p>`
    : "";

  // PAT mode: show a username input form
  const patForm = `
    ${errorHtml}
    <form method="POST" action="/auth/pat-login" style="display:flex;flex-direction:column;gap:1rem;">
      <input name="username" type="text" required
        placeholder="GitHub username"
        style="
          background: rgba(0,212,255,0.04);
          border: 1px solid rgba(0,212,255,0.15);
          border-radius: 8px;
          padding: 0.85rem 1rem;
          color: #e8ecf4;
          font-family: 'Plus Jakarta Sans', sans-serif;
          font-size: 0.95rem;
          outline: none;
          transition: border-color 0.2s;
        "
        onfocus="this.style.borderColor='rgba(0,212,255,0.4)'"
        onblur="this.style.borderColor='rgba(0,212,255,0.15)'"
      />
      <button type="submit" class="btn-github" style="justify-content:center;">
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0024 12c0-6.63-5.37-12-12-12z"/></svg>
        Verify &amp; Sign In
      </button>
    </form>`;

  // OAuth mode: show redirect button
  const oauthBtn = `
    ${errorHtml}
    <a class="btn-github" href="/auth/github">
      <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0024 12c0-6.63-5.37-12-12-12z"/></svg>
      Sign in with GitHub
    </a>`;

  const actionBlock = mode === "pat" ? patForm : oauthBtn;
  const subtitle =
    mode === "pat"
      ? "Enter your GitHub username to verify access"
      : "Sign in to access the dashboard";

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Fleet Command \u2014 Sign In</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif&family=Plus+Jakarta+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #060a14;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      font-family: 'Plus Jakarta Sans', sans-serif;
      color: #e8ecf4;
    }
    .card {
      max-width: 400px;
      width: 90%;
      background: rgba(10, 22, 40, 0.8);
      border: 1px solid rgba(0, 212, 255, 0.08);
      border-radius: 16px;
      padding: 3rem;
      text-align: center;
    }
    .card .anchor { font-size: 2.5rem; margin-bottom: 1rem; opacity: 0.7; }
    .card h1 {
      font-family: 'Instrument Serif', serif;
      font-size: 2rem;
      font-weight: 400;
      color: #e8ecf4;
      margin-bottom: 0.5rem;
    }
    .card p {
      font-size: 0.95rem;
      color: #8899b8;
      margin-bottom: 2rem;
      line-height: 1.5;
    }
    .btn-github {
      display: inline-flex;
      align-items: center;
      gap: 0.6rem;
      background: linear-gradient(135deg, #00d4ff, #0066ff);
      color: #060a14;
      border: none;
      border-radius: 8px;
      padding: 0.85rem 2rem;
      font-family: 'Plus Jakarta Sans', sans-serif;
      font-size: 0.95rem;
      font-weight: 700;
      cursor: pointer;
      text-decoration: none;
      transition: opacity 0.2s, transform 0.15s;
      width: 100%;
    }
    .btn-github:hover { opacity: 0.9; transform: translateY(-1px); }
    .btn-github:active { transform: translateY(0); }
    .btn-github svg { width: 20px; height: 20px; fill: #060a14; }
  </style>
</head>
<body>
  <div class="card">
    <div class="anchor">\u2693</div>
    <h1>Fleet Command</h1>
    <p>${subtitle}</p>
    ${actionBlock}
  </div>
</body>
</html>`;
}

// ─── Access Denied Page HTML ────────────────────────────────────────
function accessDeniedHTML(repo: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Fleet Command — Access Denied</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif&family=Plus+Jakarta+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #060a14;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      font-family: 'Plus Jakarta Sans', sans-serif;
      color: #e8ecf4;
    }
    .card {
      max-width: 400px;
      width: 90%;
      background: rgba(10, 22, 40, 0.8);
      border: 1px solid rgba(0, 212, 255, 0.08);
      border-radius: 16px;
      padding: 3rem;
      text-align: center;
    }
    .card .icon {
      font-size: 2.5rem;
      margin-bottom: 1rem;
      opacity: 0.7;
    }
    .card h1 {
      font-family: 'Instrument Serif', serif;
      font-size: 2rem;
      font-weight: 400;
      color: #ff6b6b;
      margin-bottom: 0.75rem;
    }
    .card p {
      font-size: 0.95rem;
      color: #8899b8;
      margin-bottom: 2rem;
      line-height: 1.5;
    }
    .card code {
      background: rgba(0, 212, 255, 0.08);
      padding: 0.15rem 0.5rem;
      border-radius: 4px;
      font-size: 0.9rem;
      color: #00d4ff;
    }
    .link {
      color: #00d4ff;
      text-decoration: none;
      font-weight: 600;
      font-size: 0.95rem;
      transition: opacity 0.2s;
    }
    .link:hover { opacity: 0.8; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">\u26D4</div>
    <h1>Access Denied</h1>
    <p>You need admin or write access to <code>${repo}</code> to view this dashboard.</p>
    <a class="link" href="/auth/logout">Sign in with a different account</a>
  </div>
</body>
</html>`;
}

// ─── WebSocket client tracking ───────────────────────────────────────
const wsClients = new Set<import("bun").ServerWebSocket<unknown>>();
const startTime = Date.now();

function broadcastToClients(data: FleetState): void {
  const payload = JSON.stringify(data);
  for (const ws of wsClients) {
    try {
      ws.send(payload);
    } catch {
      wsClients.delete(ws);
    }
  }
}

// ─── Data Collection ─────────────────────────────────────────────────
function readEvents(): DaemonEvent[] {
  if (!existsSync(EVENTS_FILE)) return [];
  try {
    const content = readFileSync(EVENTS_FILE, "utf-8").trim();
    if (!content) return [];
    return content
      .split("\n")
      .filter((l) => l.trim())
      .map((l) => {
        try {
          return JSON.parse(l);
        } catch {
          return null;
        }
      })
      .filter(Boolean) as DaemonEvent[];
  } catch {
    return [];
  }
}

function readDaemonState(): Record<string, unknown> | null {
  if (!existsSync(DAEMON_STATE)) return null;
  try {
    return JSON.parse(readFileSync(DAEMON_STATE, "utf-8"));
  } catch {
    return null;
  }
}

function getCpuCores(): number {
  try {
    if (process.platform === "darwin") {
      return parseInt(
        execSync("sysctl -n hw.ncpu", { encoding: "utf-8" }).trim(),
      );
    }
    // Linux: read from /proc/cpuinfo
    if (existsSync("/proc/cpuinfo")) {
      const cpuinfo = readFileSync("/proc/cpuinfo", "utf-8");
      const count = cpuinfo
        .split("\n")
        .filter((l) => l.startsWith("processor")).length;
      if (count > 0) return count;
    }
    return parseInt(execSync("nproc", { encoding: "utf-8" }).trim());
  } catch {
    return 8;
  }
}

function readLogIterations(issue: number): {
  iteration: number;
  maxIterations: number;
  linesWritten: number;
  testsPassing: boolean;
} {
  const logFile = join(LOGS_DIR, `issue-${issue}.log`);
  if (!existsSync(logFile))
    return {
      iteration: 0,
      maxIterations: 20,
      linesWritten: 0,
      testsPassing: false,
    };
  try {
    const content = readFileSync(logFile, "utf-8");
    const iters = [...content.matchAll(/Iteration (\d+)\/(\d+)/g)];
    const last = iters.length > 0 ? iters[iters.length - 1] : null;
    const lineMatches = [...content.matchAll(/(\d+) insertions?\(\+\)/g)];
    const linesWritten = lineMatches.reduce(
      (sum, m) => sum + parseInt(m[1]),
      0,
    );
    const testsPassing =
      content.includes("Tests: passed") ||
      content.toLowerCase().includes("tests passed");
    return {
      iteration: last ? parseInt(last[1]) : 0,
      maxIterations: last ? parseInt(last[2]) : 20,
      linesWritten,
      testsPassing,
    };
  } catch {
    return {
      iteration: 0,
      maxIterations: 20,
      linesWritten: 0,
      testsPassing: false,
    };
  }
}

function getFleetState(): FleetState {
  const events = readEvents();
  const daemonState = readDaemonState();
  const now = Math.floor(Date.now() / 1000);

  const state: FleetState = {
    timestamp: new Date().toISOString(),
    daemon: {
      running: false,
      pid: null,
      uptime_s: 0,
      maxParallel: 2,
      pollInterval: 30,
    },
    pipelines: [],
    queue: [],
    events: events.slice(-25),
    scale: {},
    metrics: { cpuCores: getCpuCores(), completed: 0, failed: 0 },
    agents: getAgents(),
    machines: getMachines(),
    cost: getCostInfo(),
  };

  // Daemon state
  if (daemonState) {
    state.daemon.running = true;
    state.daemon.pid = (daemonState.pid as number) || null;
    state.daemon.maxParallel = (daemonState.max_parallel as number) || 2;
    state.daemon.pollInterval = (daemonState.poll_interval as number) || 30;
    const started = daemonState.started_at as string;
    if (started) {
      try {
        state.daemon.uptime_s =
          now - Math.floor(new Date(started).getTime() / 1000);
      } catch {
        /* ignore */
      }
    }

    // Active jobs → pipelines
    const activeJobs =
      (daemonState.active_jobs as Array<Record<string, unknown>>) || [];
    for (const job of activeJobs) {
      const issue = (job.issue as number) || 0;
      const logInfo = readLogIterations(issue);
      state.pipelines.push({
        issue,
        title: (job.title as string) || "",
        stage: (job.stage as string) || "build",
        elapsed_s: now - ((job.started_epoch as number) || now),
        worktree: `daemon-issue-${issue}`,
        iteration: logInfo.iteration,
        maxIterations: logInfo.maxIterations,
        stagesDone: [],
        linesWritten: logInfo.linesWritten,
        testsPassing: logInfo.testsPassing,
      });
    }

    // Queued items — daemon stores these as plain issue numbers
    const queued =
      (daemonState.queued as Array<number | Record<string, unknown>>) || [];
    for (const q of queued) {
      if (typeof q === "number") {
        state.queue.push({ issue: q, title: "", score: 0 });
      } else {
        state.queue.push({
          issue: (q.issue as number) || 0,
          title: (q.title as string) || "",
          score: (q.score as number) || 0,
        });
      }
    }
  }

  // Extract latest scale info from events (most recent first)
  for (const e of [...events].reverse()) {
    if (e.type === "daemon.scale" && !state.scale.to) {
      state.scale = {
        from: e.from,
        to: e.to,
        maxByCpu: e.max_by_cpu,
        maxByMem: e.max_by_mem,
        maxByBudget: e.max_by_budget,
        cpuCores: e.cpu_cores,
        availMemGb: e.avail_mem_gb,
      };
    }
  }

  // Build stage history per issue + pipeline metrics
  const issueStages: Record<number, string[]> = {};
  for (const e of events) {
    if (e.issue && e.issue > 0 && e.type === "stage.completed") {
      if (!issueStages[e.issue]) issueStages[e.issue] = [];
      issueStages[e.issue].push(e.stage || "");
    }
    if (e.type === "pipeline.completed") {
      if (e.result === "success") state.metrics.completed++;
      else state.metrics.failed++;
    }
  }
  for (const p of state.pipelines) {
    if (issueStages[p.issue]) p.stagesDone = issueStages[p.issue];
  }

  return state;
}

// ─── Worktree Discovery ──────────────────────────────────────────────
function findWorktreeBase(issue: number): string | null {
  const daemonState = readDaemonState();
  if (!daemonState) return null;

  // Check active jobs for worktree path + repo
  const activeJobs =
    (daemonState.active_jobs as Array<Record<string, unknown>>) || [];
  for (const job of activeJobs) {
    if ((job.issue as number) === issue) {
      const worktree = (job.worktree as string) || "";
      const repo = (job.repo as string) || "";
      if (worktree) {
        // If repo is set, combine; otherwise try common locations
        if (repo) return join(repo, worktree);
        return resolveWorktreePath(worktree);
      }
    }
  }

  // Not in active jobs — try the default worktree naming convention
  return resolveWorktreePath(`.worktrees/daemon-issue-${issue}`);
}

function resolveWorktreePath(relative: string): string | null {
  // Try well-known repo locations
  const candidates: string[] = [];

  // Check env var
  if (process.env.VOICEAI_REPO) {
    candidates.push(join(process.env.VOICEAI_REPO, relative));
  }

  // Scan daemon state for any repo paths from completed or active jobs
  const daemonState = readDaemonState();
  if (daemonState) {
    const activeJobs =
      (daemonState.active_jobs as Array<Record<string, unknown>>) || [];
    for (const job of activeJobs) {
      const repo = (job.repo as string) || "";
      if (repo) candidates.push(join(repo, relative));
    }
  }

  // Try common parent directories where worktrees might live
  const homeDir = process.env.HOME || "";
  const commonBases = [
    join(homeDir, "Documents/voiceai"),
    join(homeDir, "Documents/claude-code-teams-tmux"),
    join(homeDir, "voiceai"),
  ];
  for (const base of commonBases) {
    candidates.push(join(base, relative));
  }

  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function readFileOr(filePath: string, fallback: string): string {
  try {
    if (existsSync(filePath)) return readFileSync(filePath, "utf-8");
  } catch {
    // ignore
  }
  return fallback;
}

// ─── Pipeline Detail ─────────────────────────────────────────────────
interface PipelineDetail {
  issue: number;
  title: string;
  stage: string;
  stageHistory: Array<{ stage: string; duration_s: number; ts: string }>;
  plan: string;
  design: string;
  dod: string;
  intake: Record<string, unknown> | null;
  elapsed_s: number;
  branch: string;
  prLink: string;
}

function getPipelineDetail(issue: number): PipelineDetail {
  const events = readEvents();
  const daemonState = readDaemonState();
  const worktreeBase = findWorktreeBase(issue);

  // Gather stage history from events
  const stageHistory: Array<{ stage: string; duration_s: number; ts: string }> =
    [];
  let currentStage = "";
  let prLink = "";
  let title = "";
  let pipelineStartEpoch = 0;

  for (const e of events) {
    if (e.issue !== issue) continue;
    if (e.type === "pipeline.started") {
      pipelineStartEpoch = e.ts_epoch || 0;
    }
    if (e.type === "stage.completed") {
      stageHistory.push({
        stage: e.stage || "",
        duration_s: e.duration_s || 0,
        ts: e.ts,
      });
    }
    if (e.type === "stage.started") {
      currentStage = e.stage || "";
    }
    if (e.type === "pipeline.completed" && e.pr_url) {
      prLink = e.pr_url as string;
    }
  }

  // Get title from daemon state
  if (daemonState) {
    const activeJobs =
      (daemonState.active_jobs as Array<Record<string, unknown>>) || [];
    for (const job of activeJobs) {
      if ((job.issue as number) === issue) {
        title = (job.title as string) || "";
      }
    }
  }

  // Read artifacts from worktree
  let plan = "";
  let design = "";
  let dod = "";
  let intake: Record<string, unknown> | null = null;
  let branch = "";

  if (worktreeBase) {
    const artifactsDir = join(worktreeBase, ".claude", "pipeline-artifacts");
    plan = readFileOr(join(artifactsDir, "plan.md"), "");
    design = readFileOr(join(artifactsDir, "design.md"), "");
    dod = readFileOr(join(artifactsDir, "dod.md"), "");

    const intakeRaw = readFileOr(join(artifactsDir, "intake.json"), "");
    if (intakeRaw) {
      try {
        intake = JSON.parse(intakeRaw);
      } catch {
        // ignore malformed JSON
      }
    }

    // Try to read current branch from worktree
    try {
      const headFile = join(worktreeBase, ".git");
      if (existsSync(headFile)) {
        const gitContent = readFileSync(headFile, "utf-8").trim();
        if (gitContent.startsWith("gitdir:")) {
          // It's a worktree — read HEAD from the gitdir
          const gitDir = gitContent.replace("gitdir: ", "").trim();
          const headPath = join(gitDir, "HEAD");
          if (existsSync(headPath)) {
            const ref = readFileSync(headPath, "utf-8").trim();
            branch = ref.startsWith("ref: refs/heads/")
              ? ref.replace("ref: refs/heads/", "")
              : ref.substring(0, 12);
          }
        } else {
          // Normal .git directory — read HEAD directly
          const headPath = join(worktreeBase, ".git", "HEAD");
          if (existsSync(headPath)) {
            const ref = readFileSync(headPath, "utf-8").trim();
            branch = ref.startsWith("ref: refs/heads/")
              ? ref.replace("ref: refs/heads/", "")
              : ref.substring(0, 12);
          }
        }
      }
    } catch {
      // ignore
    }
  }

  const now = Math.floor(Date.now() / 1000);
  const elapsed_s = pipelineStartEpoch > 0 ? now - pipelineStartEpoch : 0;

  return {
    issue,
    title,
    stage: currentStage,
    stageHistory,
    plan,
    design,
    dod,
    intake,
    elapsed_s,
    branch,
    prLink,
  };
}

// ─── Historical Metrics ──────────────────────────────────────────────
interface MetricsHistory {
  success_rate: number;
  avg_duration_s: number;
  throughput_per_hour: number;
  total_completed: number;
  total_failed: number;
  stage_durations: Record<string, number>;
  daily_counts: Array<{ date: string; completed: number; failed: number }>;
}

function getMetricsHistory(): MetricsHistory {
  const events = readEvents();
  const now = Math.floor(Date.now() / 1000);

  let completed = 0;
  let failed = 0;
  let totalDuration = 0;
  const stageDurations: Record<string, number[]> = {};
  const dailyMap: Record<string, { completed: number; failed: number }> = {};

  // Count completions in last 24h for throughput
  let completedLast24h = 0;
  const oneDayAgo = now - 86400;

  // Initialize last 7 days
  for (let i = 6; i >= 0; i--) {
    const d = new Date((now - i * 86400) * 1000);
    const key = d.toISOString().split("T")[0];
    dailyMap[key] = { completed: 0, failed: 0 };
  }

  for (const e of events) {
    if (e.type === "pipeline.completed") {
      const isSuccess = e.result === "success";
      if (isSuccess) {
        completed++;
        totalDuration += e.duration_s || 0;
      } else {
        failed++;
      }

      // Throughput: count last 24h
      if ((e.ts_epoch || 0) >= oneDayAgo && isSuccess) {
        completedLast24h++;
      }

      // Daily counts
      const dateKey = (e.ts || "").split("T")[0];
      if (dailyMap[dateKey]) {
        if (isSuccess) dailyMap[dateKey].completed++;
        else dailyMap[dateKey].failed++;
      }
    }

    if (e.type === "stage.completed" && e.stage) {
      if (!stageDurations[e.stage]) stageDurations[e.stage] = [];
      stageDurations[e.stage].push(e.duration_s || 0);
    }
  }

  const total = completed + failed;
  const avgStageDurations: Record<string, number> = {};
  for (const [stage, durations] of Object.entries(stageDurations)) {
    const sum = durations.reduce((a, b) => a + b, 0);
    avgStageDurations[stage] = Math.round(sum / durations.length);
  }

  const daily_counts = Object.entries(dailyMap)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, counts]) => ({ date, ...counts }));

  return {
    success_rate: total > 0 ? Math.round((completed / total) * 10000) / 100 : 0,
    avg_duration_s: completed > 0 ? Math.round(totalDuration / completed) : 0,
    throughput_per_hour: Math.round((completedLast24h / 24) * 100) / 100,
    total_completed: completed,
    total_failed: failed,
    stage_durations: avgStageDurations,
    daily_counts,
  };
}

// ─── Agent Heartbeats ────────────────────────────────────────────────
interface AgentInfo {
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

function getAgents(): AgentInfo[] {
  const agents: AgentInfo[] = [];
  const daemonState = readDaemonState();
  const now = Math.floor(Date.now() / 1000);

  // Build title map from active jobs
  const jobMap: Record<number, Record<string, unknown>> = {};
  if (daemonState) {
    const activeJobs =
      (daemonState.active_jobs as Array<Record<string, unknown>>) || [];
    for (const job of activeJobs) {
      const issue = (job.issue as number) || 0;
      if (issue) jobMap[issue] = job;
    }
  }

  // Read heartbeat files
  if (existsSync(HEARTBEAT_DIR)) {
    try {
      const files = readdirSync(HEARTBEAT_DIR).filter((f) =>
        f.endsWith(".json"),
      );
      for (const file of files) {
        try {
          const content = readFileSync(join(HEARTBEAT_DIR, file), "utf-8");
          const hb = JSON.parse(content);
          const updatedAt = hb.updated_at || "";
          let hbEpoch = 0;
          try {
            hbEpoch = Math.floor(new Date(updatedAt).getTime() / 1000);
          } catch {
            /* ignore */
          }
          const age = hbEpoch > 0 ? now - hbEpoch : 9999;

          let status: AgentInfo["status"] = "active";
          if (age > 120) status = "stale";
          else if (age > 30) status = "idle";

          // Check if PID is referenced in daemon active jobs
          const issue = (hb.issue as number) || 0;
          const job = issue ? jobMap[issue] : undefined;
          const startedAt = job ? (job.started_at as string) || "" : updatedAt;
          let elapsed = 0;
          if (startedAt) {
            try {
              elapsed = now - Math.floor(new Date(startedAt).getTime() / 1000);
            } catch {
              /* ignore */
            }
          }

          agents.push({
            id: file.replace(".json", ""),
            issue,
            title: job ? (job.title as string) || "" : "",
            machine: (hb.machine as string) || "localhost",
            stage: (hb.stage as string) || "",
            iteration: (hb.iteration as number) || 0,
            activity: (hb.last_activity as string) || "",
            memory_mb: (hb.memory_mb as number) || 0,
            cpu_pct: (hb.cpu_pct as number) || 0,
            status,
            heartbeat_age_s: age,
            started_at: startedAt,
            elapsed_s: elapsed,
          });
        } catch {
          // Skip malformed heartbeat files
        }
      }
    } catch {
      // Heartbeat dir read failed
    }
  }

  return agents;
}

// ─── Timeline ──────────────────────────────────────────────────────
interface TimelineEntry {
  issue: number;
  title: string;
  segments: Array<{
    stage: string;
    start: string;
    end: string | null;
    status: "complete" | "running" | "failed";
  }>;
}

function getTimeline(rangeHours: number): TimelineEntry[] {
  const events = readEvents();
  const daemonState = readDaemonState();
  const now = Math.floor(Date.now() / 1000);
  const cutoff = now - rangeHours * 3600;

  // Build issue title map
  const titleMap: Record<number, string> = {};
  if (daemonState) {
    const activeJobs =
      (daemonState.active_jobs as Array<Record<string, unknown>>) || [];
    for (const job of activeJobs) {
      const issue = (job.issue as number) || 0;
      const title = (job.title as string) || "";
      if (issue && title) titleMap[issue] = title;
    }
  }

  // Group events by issue
  const issueEvents: Record<number, DaemonEvent[]> = {};
  for (const e of events) {
    if (!e.issue || e.issue <= 0) continue;
    const epoch = e.ts_epoch || 0;
    if (epoch < cutoff) continue;
    if (!issueEvents[e.issue]) issueEvents[e.issue] = [];
    issueEvents[e.issue].push(e);
    if (e.type === "pipeline.completed" && !titleMap[e.issue]) {
      titleMap[e.issue] = (e.title as string) || "";
    }
  }

  const timeline: TimelineEntry[] = [];
  for (const [issueStr, evts] of Object.entries(issueEvents)) {
    const issue = parseInt(issueStr);
    const segments: TimelineEntry["segments"] = [];

    for (const e of evts) {
      if (e.type === "stage.started") {
        segments.push({
          stage: e.stage || "",
          start: e.ts,
          end: null,
          status: "running",
        });
      }
      if (e.type === "stage.completed") {
        // Find matching running segment
        for (let i = segments.length - 1; i >= 0; i--) {
          if (
            segments[i].stage === e.stage &&
            segments[i].status === "running"
          ) {
            segments[i].end = e.ts;
            segments[i].status = "complete";
            break;
          }
        }
      }
      if (e.type === "stage.failed") {
        for (let i = segments.length - 1; i >= 0; i--) {
          if (
            segments[i].stage === e.stage &&
            segments[i].status === "running"
          ) {
            segments[i].end = e.ts;
            segments[i].status = "failed";
            break;
          }
        }
      }
    }

    if (segments.length > 0) {
      timeline.push({
        issue,
        title: titleMap[issue] || "",
        segments,
      });
    }
  }

  return timeline;
}

// ─── Machines ──────────────────────────────────────────────────────
interface MachineInfo {
  name: string;
  host: string;
  role: string;
  max_workers: number;
  registered_at: string;
}

function getMachines(): MachineInfo[] {
  if (!existsSync(MACHINES_FILE)) return [];
  try {
    const data = JSON.parse(readFileSync(MACHINES_FILE, "utf-8"));
    return (data.machines || []).map((m: Record<string, unknown>) => ({
      name: (m.name as string) || "",
      host: (m.host as string) || "",
      role: (m.role as string) || "worker",
      max_workers: (m.max_workers as number) || 4,
      registered_at: (m.registered_at as string) || "",
    }));
  } catch {
    return [];
  }
}

// ─── Cost Data ─────────────────────────────────────────────────────
interface CostInfo {
  today_spent: number;
  daily_budget: number;
  pct_used: number;
}

function getCostInfo(): CostInfo {
  let todaySpent = 0;
  let dailyBudget = 0;

  if (existsSync(COSTS_FILE)) {
    try {
      const data = JSON.parse(readFileSync(COSTS_FILE, "utf-8"));
      // Cost file format: {entries: [{cost_usd, ts_epoch, ...}]}
      // Sum entries from today (midnight UTC)
      const entries = (data.entries as Array<Record<string, unknown>>) || [];
      const todayMidnight = new Date();
      todayMidnight.setUTCHours(0, 0, 0, 0);
      const cutoff = Math.floor(todayMidnight.getTime() / 1000);
      for (const entry of entries) {
        const epoch = (entry.ts_epoch as number) || 0;
        if (epoch >= cutoff) {
          todaySpent += (entry.cost_usd as number) || 0;
        }
      }
      todaySpent = Math.round(todaySpent * 100) / 100;
    } catch {
      /* ignore */
    }
  }

  if (existsSync(BUDGET_FILE)) {
    try {
      const data = JSON.parse(readFileSync(BUDGET_FILE, "utf-8"));
      // Budget file format: {daily_budget_usd: N, enabled: bool}
      dailyBudget = (data.daily_budget_usd as number) || 0;
    } catch {
      /* ignore */
    }
  }

  const pctUsed =
    dailyBudget > 0 ? Math.round((todaySpent / dailyBudget) * 10000) / 100 : 0;
  return {
    today_spent: todaySpent,
    daily_budget: dailyBudget,
    pct_used: pctUsed,
  };
}

// ─── Plan Content ────────────────────────────────────────────────────
function getPlanContent(issue: number): { content: string } {
  const worktreeBase = findWorktreeBase(issue);
  if (!worktreeBase) return { content: "" };
  const planPath = join(
    worktreeBase,
    ".claude",
    "pipeline-artifacts",
    "plan.md",
  );
  return { content: readFileOr(planPath, "") };
}

// ─── Activity Feed ───────────────────────────────────────────────────
interface ActivityEvent extends DaemonEvent {
  issueTitle?: string;
}

interface ActivityFeed {
  events: ActivityEvent[];
  total: number;
  hasMore: boolean;
}

function getActivityFeed(
  limit: number,
  offset: number,
  typeFilter: string,
  issueFilter: string,
): ActivityFeed {
  const allEvents = readEvents();
  const daemonState = readDaemonState();

  // Build issue title map from daemon state
  const titleMap: Record<number, string> = {};
  if (daemonState) {
    const activeJobs =
      (daemonState.active_jobs as Array<Record<string, unknown>>) || [];
    for (const job of activeJobs) {
      const issue = (job.issue as number) || 0;
      const title = (job.title as string) || "";
      if (issue && title) titleMap[issue] = title;
    }
  }

  // Filter events
  let filtered = allEvents;
  if (typeFilter && typeFilter !== "all") {
    filtered = filtered.filter(
      (e) => e.type === typeFilter || e.type.startsWith(typeFilter + "."),
    );
  }
  if (issueFilter) {
    const issueNum = parseInt(issueFilter);
    if (!isNaN(issueNum)) {
      filtered = filtered.filter((e) => e.issue === issueNum);
    }
  }

  // Reverse for newest-first
  filtered = [...filtered].reverse();
  const total = filtered.length;
  const page = filtered.slice(offset, offset + limit);

  // Enrich with titles
  const enriched: ActivityEvent[] = page.map((e) => ({
    ...e,
    issueTitle: e.issue ? titleMap[e.issue] || "" : undefined,
  }));

  return {
    events: enriched,
    total,
    hasMore: offset + limit < total,
  };
}

// ─── Linear Integration Status ───────────────────────────────────────
interface LinearStatus {
  configured: boolean;
  configSource: string;
  linkedIssues: Record<string, unknown>;
}

function getLinearStatus(): LinearStatus {
  const hasEnvKey = !!process.env.LINEAR_API_KEY;
  const configPath = join(HOME, ".claude-teams", "linear-config.json");
  const hasConfigFile = existsSync(configPath);

  let linkedIssues: Record<string, unknown> = {};
  if (hasConfigFile) {
    try {
      const config = JSON.parse(readFileSync(configPath, "utf-8"));
      linkedIssues = (config.linked_issues as Record<string, unknown>) || {};
    } catch {
      // ignore
    }
  }

  return {
    configured: hasEnvKey || hasConfigFile,
    configSource: hasEnvKey ? "env" : hasConfigFile ? "file" : "none",
    linkedIssues,
  };
}

// ─── Static file serving ─────────────────────────────────────────────
const MIME_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
};

function serveStaticFile(pathname: string): Response | null {
  // Map / to /index.html
  const filePath =
    pathname === "/" || pathname === "/index.html"
      ? join(PUBLIC_DIR, "index.html")
      : join(PUBLIC_DIR, pathname);

  // Prevent directory traversal
  if (!filePath.startsWith(PUBLIC_DIR)) {
    return new Response("Forbidden", { status: 403 });
  }

  const file = Bun.file(filePath);
  // Bun.file doesn't throw on missing files — check existence
  if (!existsSync(filePath)) return null;

  const ext = extname(filePath);
  const contentType = MIME_TYPES[ext] || "application/octet-stream";

  return new Response(file, {
    headers: {
      "Content-Type": contentType,
      "Cache-Control": "no-cache",
    },
  });
}

// ─── File watcher for events.jsonl ───────────────────────────────────
let eventsWatcher: FSWatcher | null = null;

function startEventsWatcher(): void {
  // Watch the directory containing events.jsonl (file may not exist yet)
  const watchDir = join(HOME, ".claude-teams");
  if (!existsSync(watchDir)) return;

  try {
    eventsWatcher = watch(watchDir, (eventType, filename) => {
      if (filename === "events.jsonl" || filename === "daemon-state.json") {
        // Push fresh state to all connected clients immediately
        if (wsClients.size > 0) {
          broadcastToClients(getFleetState());
        }
      }
    });
  } catch {
    // Watcher may fail on some systems — fall back to interval-only
  }
}

// ─── Periodic WebSocket push ─────────────────────────────────────────
let lastPushedJson = "";

function periodicPush(): void {
  if (wsClients.size === 0) return;

  const state = getFleetState();
  const json = JSON.stringify(state);
  // Skip push if nothing changed (file watcher already pushed)
  if (json === lastPushedJson) return;
  lastPushedJson = json;

  broadcastToClients(state);
}

// ─── GitHub OAuth helpers ───────────────────────────────────────────
async function exchangeCodeForToken(code: string): Promise<string | null> {
  try {
    const resp = await fetch("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        client_id: GITHUB_CLIENT_ID,
        client_secret: GITHUB_CLIENT_SECRET,
        code,
      }),
    });
    const data = (await resp.json()) as { access_token?: string };
    return data.access_token || null;
  } catch {
    return null;
  }
}

async function getGitHubUser(
  token: string,
): Promise<{ login: string; avatar_url: string } | null> {
  try {
    const resp = await fetch("https://api.github.com/user", {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "User-Agent": "Shipwright-Fleet-Command",
      },
    });
    if (!resp.ok) return null;
    const data = (await resp.json()) as { login: string; avatar_url: string };
    return data;
  } catch {
    return null;
  }
}

async function checkRepoPermission(
  token: string,
  username: string,
): Promise<string | null> {
  if (!DASHBOARD_REPO) return null;
  const [owner, repo] = DASHBOARD_REPO.split("/");
  if (!owner || !repo) return null;

  try {
    const resp = await fetch(
      `https://api.github.com/repos/${owner}/${repo}/collaborators/${username}/permission`,
      {
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/vnd.github+json",
          "User-Agent": "Shipwright-Fleet-Command",
        },
      },
    );
    if (!resp.ok) return null;
    const data = (await resp.json()) as { permission?: string };
    return data.permission || null;
  } catch {
    return null;
  }
}

// ─── Auth route handlers ────────────────────────────────────────────
function handleAuthGitHub(): Response {
  const params = new URLSearchParams({
    client_id: GITHUB_CLIENT_ID,
    scope: "read:org repo",
    redirect_uri: "", // GitHub uses the registered callback URL by default
  });
  // Remove empty redirect_uri — let GitHub use the app's registered callback
  params.delete("redirect_uri");

  return new Response(null, {
    status: 302,
    headers: {
      Location: `https://github.com/login/oauth/authorize?${params.toString()}`,
    },
  });
}

async function handleAuthCallback(url: URL): Promise<Response> {
  const code = url.searchParams.get("code");
  if (!code) {
    return new Response("Missing code parameter", { status: 400 });
  }

  // Exchange code for access token
  const accessToken = await exchangeCodeForToken(code);
  if (!accessToken) {
    return new Response("Failed to exchange code for token", { status: 500 });
  }

  // Get GitHub user info
  const user = await getGitHubUser(accessToken);
  if (!user) {
    return new Response("Failed to get user info", { status: 500 });
  }

  // Check repo permission
  const permission = await checkRepoPermission(accessToken, user.login);
  const isAdmin = !!permission && ALLOWED_PERMISSIONS.includes(permission);

  if (!isAdmin) {
    return new Response(accessDeniedHTML(DASHBOARD_REPO), {
      status: 403,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  }

  // Create session and redirect to dashboard
  const sessionId = createSession({
    githubUser: user.login,
    accessToken,
    avatarUrl: user.avatar_url,
    isAdmin,
  });

  return new Response(null, {
    status: 302,
    headers: {
      Location: "/",
      "Set-Cookie": sessionCookie(sessionId),
    },
  });
}

function handleAuthLogout(req: Request): Response {
  // Remove session from store
  const cookie = req.headers.get("cookie");
  if (cookie) {
    const match = cookie.match(/fleet_session=([^;]+)/);
    if (match) sessions.delete(match[1]);
  }

  return new Response(null, {
    status: 302,
    headers: {
      Location: "/login",
      "Set-Cookie": clearSessionCookie(),
    },
  });
}

// ─── PAT-based login handler ─────────────────────────────────────────
async function handlePatLogin(req: Request): Promise<Response> {
  // Parse form body
  const formData = await req.formData();
  const username = ((formData.get("username") as string) || "").trim();

  if (!username) {
    return new Response(loginPageHTML("Please enter a GitHub username"), {
      status: 400,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  }

  // Use the PAT to check this user's permission on the target repo
  const permission = await checkRepoPermission(GITHUB_PAT, username);
  const isAdmin = !!permission && ALLOWED_PERMISSIONS.includes(permission);

  if (!isAdmin) {
    return new Response(accessDeniedHTML(DASHBOARD_REPO), {
      status: 403,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  }

  // Fetch their avatar URL for the dashboard
  let avatarUrl = "";
  try {
    const resp = await fetch(`https://api.github.com/users/${username}`, {
      headers: {
        Authorization: `Bearer ${GITHUB_PAT}`,
        Accept: "application/vnd.github+json",
        "User-Agent": "Shipwright-Fleet-Command",
      },
    });
    if (resp.ok) {
      const data = (await resp.json()) as {
        avatar_url?: string;
        name?: string;
      };
      avatarUrl = data.avatar_url || "";
    }
  } catch {
    // Non-critical — proceed without avatar
  }

  const sessionId = createSession({
    githubUser: username,
    accessToken: "", // PAT mode doesn't give per-user tokens
    avatarUrl,
    isAdmin,
  });

  return new Response(null, {
    status: 302,
    headers: {
      Location: "/",
      "Set-Cookie": sessionCookie(sessionId),
    },
  });
}

// ─── HTTP + WebSocket server ─────────────────────────────────────────
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

const server = Bun.serve({
  port: PORT,

  async fetch(req, server) {
    const url = new URL(req.url);
    const pathname = url.pathname;

    // CORS preflight
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    // ── Public routes (no auth required) ──────────────────────────

    // Health check — always public
    if (pathname === "/api/health") {
      const health: HealthResponse = {
        status: "ok",
        uptime_s: Math.floor((Date.now() - startTime) / 1000),
        connections: wsClients.size,
      };
      return new Response(JSON.stringify(health), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // Auth routes
    if (pathname === "/login") {
      if (!isAuthEnabled()) {
        // No auth configured — serve dashboard directly
        const staticResponse = serveStaticFile("/");
        if (staticResponse) return staticResponse;
        return new Response("Dashboard not found", { status: 404 });
      }
      return new Response(loginPageHTML(), {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    if (pathname === "/auth/github") {
      if (getAuthMode() !== "oauth") {
        return new Response("OAuth not configured", { status: 500 });
      }
      return handleAuthGitHub();
    }

    if (pathname === "/auth/callback") {
      if (getAuthMode() !== "oauth") {
        return new Response("OAuth not configured", { status: 500 });
      }
      return handleAuthCallback(url);
    }

    if (pathname === "/auth/pat-login" && req.method === "POST") {
      if (getAuthMode() !== "pat") {
        return new Response("PAT auth not configured", { status: 500 });
      }
      return handlePatLogin(req);
    }

    if (pathname === "/auth/logout") {
      return handleAuthLogout(req);
    }

    // ── Auth gate ─────────────────────────────────────────────────
    // If auth is enabled, enforce it on all remaining routes
    if (isAuthEnabled()) {
      const session = getSession(req);
      if (!session) {
        // WebSocket upgrade attempt without auth
        if (pathname === "/ws") {
          return new Response("Unauthorized", { status: 401 });
        }
        return new Response(null, {
          status: 302,
          headers: { Location: "/login" },
        });
      }
    }

    // ── Protected routes ──────────────────────────────────────────

    // WebSocket upgrade
    if (pathname === "/ws") {
      const upgraded = server.upgrade(req);
      if (upgraded) return undefined as unknown as Response;
      return new Response("WebSocket upgrade failed", { status: 400 });
    }

    // REST: fleet state
    if (pathname === "/api/status") {
      return new Response(JSON.stringify(getFleetState()), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: pipeline detail for a specific issue
    if (pathname.startsWith("/api/pipeline/")) {
      const issueNum = parseInt(pathname.split("/")[3] || "0");
      if (!issueNum || isNaN(issueNum)) {
        return new Response(JSON.stringify({ error: "Invalid issue number" }), {
          status: 400,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
      return new Response(JSON.stringify(getPipelineDetail(issueNum)), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: historical metrics aggregated from events.jsonl
    if (pathname === "/api/metrics/history") {
      return new Response(JSON.stringify(getMetricsHistory()), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: plan markdown for a specific issue
    if (pathname.startsWith("/api/plans/")) {
      const issueNum = parseInt(pathname.split("/")[3] || "0");
      if (!issueNum || isNaN(issueNum)) {
        return new Response(JSON.stringify({ error: "Invalid issue number" }), {
          status: 400,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
      return new Response(JSON.stringify(getPlanContent(issueNum)), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: enhanced activity feed with pagination and filtering
    if (pathname === "/api/activity") {
      const limit = Math.min(
        parseInt(url.searchParams.get("limit") || "50"),
        200,
      );
      const offset = parseInt(url.searchParams.get("offset") || "0");
      const typeFilter = url.searchParams.get("type") || "all";
      const issueFilter = url.searchParams.get("issue") || "";
      return new Response(
        JSON.stringify(getActivityFeed(limit, offset, typeFilter, issueFilter)),
        { headers: { "Content-Type": "application/json", ...CORS_HEADERS } },
      );
    }

    // REST: Agent heartbeats
    if (pathname === "/api/agents") {
      return new Response(JSON.stringify(getAgents()), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Timeline (Gantt data)
    if (pathname === "/api/timeline") {
      const rangeParam = url.searchParams.get("range") || "24h";
      const hours = parseInt(rangeParam) || 24;
      return new Response(JSON.stringify(getTimeline(hours)), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Intervention actions
    if (pathname.startsWith("/api/intervention/") && req.method === "POST") {
      const parts = pathname.split("/");
      const issueNum = parseInt(parts[3]);
      const action = parts[4]; // pause, resume, abort, message, skip
      if (!issueNum || !action) {
        return new Response(JSON.stringify({ error: "Invalid intervention" }), {
          status: 400,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }

      // Find PID from daemon state
      const daemonState = readDaemonState();
      let pid: number | null = null;
      let worktreeBase: string | null = null;
      if (daemonState) {
        const activeJobs =
          (daemonState.active_jobs as Array<Record<string, unknown>>) || [];
        for (const job of activeJobs) {
          if ((job.issue as number) === issueNum) {
            pid = (job.pid as number) || null;
            const wt = (job.worktree as string) || "";
            const repo = (job.repo as string) || "";
            if (wt && repo) worktreeBase = join(repo, wt);
            break;
          }
        }
      }

      try {
        switch (action) {
          case "pause":
            if (pid) execSync(`kill -STOP ${pid}`);
            break;
          case "resume":
            if (pid) execSync(`kill -CONT ${pid}`);
            break;
          case "abort":
            if (pid) execSync(`kill -TERM ${pid}`);
            break;
          case "message": {
            const body = (await req.json()) as { message?: string };
            const msg = body.message || "";
            if (worktreeBase && msg) {
              const msgDir = join(
                worktreeBase,
                ".claude",
                "pipeline-artifacts",
              );
              mkdirSync(msgDir, { recursive: true });
              const tmpFile = join(msgDir, "human-message.txt.tmp");
              const msgFile = join(msgDir, "human-message.txt");
              writeFileSync(tmpFile, msg, "utf-8");
              renameSync(tmpFile, msgFile);
            }
            break;
          }
          case "skip": {
            if (worktreeBase) {
              const artDir = join(
                worktreeBase,
                ".claude",
                "pipeline-artifacts",
              );
              mkdirSync(artDir, { recursive: true });
              const tmpFile = join(artDir, "skip-stage.txt.tmp");
              const skipFile = join(artDir, "skip-stage.txt");
              writeFileSync(tmpFile, "skip", "utf-8");
              renameSync(tmpFile, skipFile);
            }
            break;
          }
          default:
            return new Response(JSON.stringify({ error: "Unknown action" }), {
              status: 400,
              headers: { "Content-Type": "application/json", ...CORS_HEADERS },
            });
        }
        return new Response(
          JSON.stringify({ ok: true, action, issue: issueNum }),
          { headers: { "Content-Type": "application/json", ...CORS_HEADERS } },
        );
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // REST: Linear integration status
    if (pathname === "/api/linear/status") {
      return new Response(JSON.stringify(getLinearStatus()), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: current user info
    if (pathname === "/api/me") {
      if (!isAuthEnabled()) {
        return new Response(
          JSON.stringify({ username: "local", avatarUrl: "", isAdmin: true }),
          { headers: { "Content-Type": "application/json", ...CORS_HEADERS } },
        );
      }
      const session = getSession(req);
      if (!session) {
        return new Response(JSON.stringify({ error: "Not authenticated" }), {
          status: 401,
          headers: { "Content-Type": "application/json" },
        });
      }
      return new Response(
        JSON.stringify({
          username: session.githubUser,
          avatarUrl: session.avatarUrl,
          isAdmin: session.isAdmin,
        }),
        { headers: { "Content-Type": "application/json", ...CORS_HEADERS } },
      );
    }

    // Static files from public/
    const staticResponse = serveStaticFile(pathname);
    if (staticResponse) return staticResponse;

    return new Response("Not Found", { status: 404 });
  },

  websocket: {
    open(ws) {
      wsClients.add(ws);
      // Send initial state immediately on connect
      try {
        ws.send(JSON.stringify(getFleetState()));
      } catch {
        wsClients.delete(ws);
      }
    },
    message(_ws, _message) {
      // Clients don't send meaningful messages; server is push-only
    },
    close(ws) {
      wsClients.delete(ws);
    },
  },
});

// Start background tasks
startEventsWatcher();
const pushInterval = setInterval(periodicPush, WS_PUSH_INTERVAL_MS);

// Graceful shutdown
process.on("SIGINT", () => {
  clearInterval(pushInterval);
  if (eventsWatcher) eventsWatcher.close();
  for (const ws of wsClients) {
    try {
      ws.close(1001, "Server shutting down");
    } catch {
      // ignore
    }
  }
  wsClients.clear();
  server.stop();
  process.exit(0);
});

// ─── Startup banner ──────────────────────────────────────────────────
const authModeLabel = (() => {
  const m = getAuthMode();
  if (m === "oauth")
    return `${GREEN}\u25CF${RESET} Auth: GitHub OAuth (repo: ${DASHBOARD_REPO})`;
  if (m === "pat")
    return `${GREEN}\u25CF${RESET} Auth: PAT-verified (repo: ${DASHBOARD_REPO})`;
  return `${DIM}\u25CB Auth: disabled (set GITHUB_PAT + DASHBOARD_REPO, or GITHUB_CLIENT_ID + GITHUB_CLIENT_SECRET + DASHBOARD_REPO)${RESET}`;
})();

console.log(
  `\n  ${CYAN}\u2693${RESET} ${BOLD}Shipwright Fleet Command${RESET}`,
);
console.log(
  `  ${GREEN}\u25CF${RESET} Dashboard: ${ULINE}http://localhost:${server.port}${RESET}`,
);
console.log(
  `  ${GREEN}\u25CF${RESET} API:       ${ULINE}http://localhost:${server.port}/api/status${RESET}`,
);
console.log(
  `  ${GREEN}\u25CF${RESET} WebSocket: ${ULINE}ws://localhost:${server.port}/ws${RESET}`,
);
console.log(
  `  ${GREEN}\u25CF${RESET} Health:    ${ULINE}http://localhost:${server.port}/api/health${RESET}`,
);
console.log(`  ${authModeLabel}`);
console.log(
  `  ${DIM}Push interval: ${WS_PUSH_INTERVAL_MS}ms | File watcher: ${eventsWatcher ? "active" : "fallback to interval"}${RESET}\n`,
);
