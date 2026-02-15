import {
  readFileSync,
  readdirSync,
  writeFileSync,
  renameSync,
  mkdirSync,
  existsSync,
  unlinkSync,
  appendFileSync,
  watch,
  type FSWatcher,
} from "fs";
import { join, extname } from "path";
import { execSync } from "child_process";
import { Database } from "bun:sqlite";

// ─── Config ──────────────────────────────────────────────────────────
const PORT = parseInt(
  process.argv[2] || process.env.SHIPWRIGHT_DASHBOARD_PORT || "8767",
);
const HOME = process.env.HOME || "";
const EVENTS_FILE = join(HOME, ".shipwright", "events.jsonl");
const DAEMON_STATE = join(HOME, ".shipwright", "daemon-state.json");
const LOGS_DIR = join(HOME, ".shipwright", "logs");
const HEARTBEAT_DIR = join(HOME, ".shipwright", "heartbeats");
const MACHINES_FILE = join(HOME, ".shipwright", "machines.json");
const COSTS_FILE = join(HOME, ".shipwright", "costs.json");
const BUDGET_FILE = join(HOME, ".shipwright", "budget.json");
const MEMORY_DIR = join(HOME, ".shipwright", "memory");
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

// ─── SQLite Database (optional) ──────────────────────────────────────
const DB_FILE = join(HOME, ".shipwright", "shipwright.db");
let db: Database | null = null;

function getDb(): Database | null {
  if (db) return db;
  try {
    if (!existsSync(DB_FILE)) return null;
    db = new Database(DB_FILE, { readonly: true });
    db.exec("PRAGMA journal_mode=WAL;");
    return db;
  } catch {
    return null;
  }
}

function dbQueryEvents(since?: number, limit = 200): DaemonEvent[] {
  const conn = getDb();
  if (!conn) return [];
  try {
    const cutoff = since || 0;
    const rows = conn
      .query(
        `SELECT ts, ts_epoch, type, job_id, stage, status, duration_secs, metadata
         FROM events WHERE ts_epoch >= ? ORDER BY ts_epoch DESC LIMIT ?`,
      )
      .all(cutoff, limit) as Array<Record<string, unknown>>;
    return rows.map((r) => {
      const base: DaemonEvent = {
        ts: r.ts as string,
        ts_epoch: r.ts_epoch as number,
        type: r.type as string,
      };
      if (r.job_id)
        base.issue = parseInt(String(r.job_id).replace(/\D/g, "")) || undefined;
      if (r.stage) base.stage = r.stage as string;
      if (r.duration_secs) base.duration_s = r.duration_secs as number;
      if (r.status) base.result = r.status as string;
      if (r.metadata) {
        try {
          Object.assign(base, JSON.parse(r.metadata as string));
        } catch {
          /* ignore malformed metadata */
        }
      }
      return base;
    });
  } catch {
    return [];
  }
}

function dbQueryJobs(status?: string): Array<Record<string, unknown>> {
  const conn = getDb();
  if (!conn) return [];
  try {
    if (status) {
      return conn
        .query(
          "SELECT * FROM daemon_state WHERE status = ? ORDER BY started_at DESC",
        )
        .all(status) as Array<Record<string, unknown>>;
    }
    return conn
      .query("SELECT * FROM daemon_state ORDER BY started_at DESC LIMIT 50")
      .all() as Array<Record<string, unknown>>;
  } catch {
    return [];
  }
}

function dbQueryCostsToday(): { total: number; count: number } {
  const conn = getDb();
  if (!conn) return { total: 0, count: 0 };
  try {
    const todayStart = new Date();
    todayStart.setUTCHours(0, 0, 0, 0);
    const epoch = Math.floor(todayStart.getTime() / 1000);
    const row = conn
      .query(
        "SELECT COALESCE(SUM(cost_usd), 0) as total, COUNT(*) as count FROM cost_entries WHERE ts_epoch >= ?",
      )
      .get(epoch) as { total: number; count: number } | null;
    return row || { total: 0, count: 0 };
  } catch {
    return { total: 0, count: 0 };
  }
}

function dbQueryHeartbeats(): Array<Record<string, unknown>> {
  const conn = getDb();
  if (!conn) return [];
  try {
    return conn
      .query("SELECT * FROM heartbeats ORDER BY updated_at DESC")
      .all() as Array<Record<string, unknown>>;
  } catch {
    return [];
  }
}

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

interface DoraMetric {
  value: number;
  unit: string;
  grade: "Elite" | "High" | "Medium" | "Low";
}

interface DoraGrades {
  deploy_freq: DoraMetric;
  lead_time: DoraMetric;
  cfr: DoraMetric;
  mttr: DoraMetric;
}

interface ConnectedDeveloper {
  developer_id: string;
  machine_name: string;
  hostname: string;
  platform: string;
  last_heartbeat: number; // epoch ms
  daemon_running: boolean;
  daemon_pid: number | null;
  active_jobs: Array<{ issue: number; title: string; stage: string }>;
  queued: number[];
  events_since: number; // last synced event timestamp
}

interface TeamState {
  developers: Array<ConnectedDeveloper & { _presence?: string }>;
  total_online: number;
  total_active_pipelines: number;
  total_queued: number;
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
  dora: DoraGrades;
  team?: TeamState;
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
  saveSessions();
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
    saveSessions();
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

// ─── File-backed Sessions ───────────────────────────────────────────
const SESSIONS_FILE = join(HOME, ".shipwright", "sessions.json");

function loadSessions(): void {
  try {
    if (existsSync(SESSIONS_FILE)) {
      const data = JSON.parse(readFileSync(SESSIONS_FILE, "utf-8"));
      const now = Date.now();
      if (data && typeof data === "object") {
        for (const [id, sess] of Object.entries(data)) {
          const s = sess as Session;
          if (s.expiresAt > now) {
            sessions.set(id, s);
          }
        }
      }
    }
  } catch {
    /* start fresh */
  }
}

function saveSessions(): void {
  const dir = join(HOME, ".shipwright");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const obj: Record<string, Session> = {};
  for (const [id, sess] of sessions) {
    obj[id] = sess;
  }
  const tmp = SESSIONS_FILE + ".tmp";
  writeFileSync(tmp, JSON.stringify(obj, null, 2));
  renameSync(tmp, SESSIONS_FILE);
}

// ─── Developer Registry ─────────────────────────────────────────────
const DEVELOPER_REGISTRY_FILE = join(
  HOME,
  ".shipwright",
  "developer-registry.json",
);
const TEAM_EVENTS_FILE = join(HOME, ".shipwright", "team-events.jsonl");
const developerRegistry = new Map<string, ConnectedDeveloper>();

function loadDeveloperRegistry(): void {
  try {
    if (existsSync(DEVELOPER_REGISTRY_FILE)) {
      const data = JSON.parse(readFileSync(DEVELOPER_REGISTRY_FILE, "utf-8"));
      if (Array.isArray(data)) {
        for (const dev of data) {
          const key = `${dev.developer_id}@${dev.machine_name}`;
          developerRegistry.set(key, dev);
        }
      }
    }
  } catch {
    /* start fresh */
  }
}

function saveDeveloperRegistry(): void {
  const dir = join(HOME, ".shipwright");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const data = JSON.stringify(Array.from(developerRegistry.values()), null, 2);
  const tmp = DEVELOPER_REGISTRY_FILE + ".tmp";
  writeFileSync(tmp, data);
  renameSync(tmp, DEVELOPER_REGISTRY_FILE);
}

function getPresenceStatus(
  lastHeartbeat: number,
): "online" | "idle" | "offline" {
  const age = Date.now() - lastHeartbeat;
  if (age < 30_000) return "online";
  if (age < 120_000) return "idle";
  return "offline";
}

function getTeamState(): TeamState {
  const developers = Array.from(developerRegistry.values()).filter(
    (d) => Date.now() - d.last_heartbeat < 86_400_000,
  ); // exclude >24h offline
  const online = developers.filter(
    (d) => getPresenceStatus(d.last_heartbeat) === "online",
  );
  return {
    developers: developers.map((d) => ({
      ...d,
      _presence: getPresenceStatus(d.last_heartbeat),
    })),
    total_online: online.length,
    total_active_pipelines: developers.reduce(
      (sum, d) => sum + d.active_jobs.length,
      0,
    ),
    total_queued: developers.reduce((sum, d) => sum + d.queued.length, 0),
  };
}

// Invite tokens (file-backed, separate from join-tokens)
const INVITE_TOKENS_FILE = join(HOME, ".shipwright", "invite-tokens.json");
const inviteTokens = new Map<
  string,
  { token: string; created_at: string; expires_at: string }
>();

function loadInviteTokens(): void {
  try {
    if (existsSync(INVITE_TOKENS_FILE)) {
      const data = JSON.parse(readFileSync(INVITE_TOKENS_FILE, "utf-8"));
      if (Array.isArray(data)) {
        const now = Date.now();
        for (const t of data) {
          // Skip expired tokens on load
          if (new Date(t.expires_at).getTime() > now) {
            inviteTokens.set(t.token, t);
          }
        }
      }
    }
  } catch {
    /* start fresh */
  }
}

function saveInviteTokens(): void {
  const dir = join(HOME, ".shipwright");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const data = JSON.stringify(Array.from(inviteTokens.values()), null, 2);
  const tmp = INVITE_TOKENS_FILE + ".tmp";
  writeFileSync(tmp, data);
  renameSync(tmp, INVITE_TOKENS_FILE);
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
    pathname === "/api/health" ||
    pathname.startsWith("/api/join/") ||
    pathname.startsWith("/api/connect/") ||
    pathname === "/api/team" ||
    pathname === "/api/team/activity" ||
    pathname === "/api/team/invite" ||
    pathname.startsWith("/api/team/invite/") ||
    pathname === "/api/claim" ||
    pathname === "/api/claim/release" ||
    pathname === "/api/webhook/ci"
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
  // Try SQLite first (faster for large event logs)
  const dbEvents = dbQueryEvents(0, 10000);
  if (dbEvents.length > 0) return dbEvents;

  // Fallback to JSONL
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
    dora: calculateDoraGrades(events, 7),
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

  // Add team data if any developers are connected
  if (developerRegistry.size > 0) {
    state.team = getTeamState();
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
  dora_grades: DoraGrades;
}

function getMetricsHistory(doraPeriodDays: number = 7): MetricsHistory {
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
    dora_grades: calculateDoraGrades(events, doraPeriodDays),
  };
}

// ─── DORA Grades ────────────────────────────────────────────────────
function calculateDoraGrades(
  events: DaemonEvent[],
  periodDays: number,
): DoraGrades {
  const now = Math.floor(Date.now() / 1000);
  const cutoff = now - periodDays * 86400;

  // Filter to events within the period
  const recent = events.filter((e) => (e.ts_epoch || 0) >= cutoff);

  // --- Deployment Frequency ---
  // Count successful completions in the period
  let completedCount = 0;
  for (const e of recent) {
    if (e.type === "pipeline.completed" && e.result === "success") {
      completedCount++;
    }
  }
  const deploysPerDay =
    periodDays > 0 ? Math.round((completedCount / periodDays) * 100) / 100 : 0;

  let deployGrade: DoraMetric["grade"];
  if (deploysPerDay >= 1) deployGrade = "Elite";
  else if (deploysPerDay >= 1 / 7) deployGrade = "High";
  else if (deploysPerDay >= 1 / 30) deployGrade = "Medium";
  else deployGrade = "Low";

  // --- Lead Time ---
  // Average time from pipeline.started to pipeline.completed (success only)
  const leadTimes: number[] = [];
  const startEpochs: Record<number, number> = {};
  for (const e of recent) {
    if (e.type === "pipeline.started" && e.issue) {
      startEpochs[e.issue] = e.ts_epoch || 0;
    }
    if (e.type === "pipeline.completed" && e.result === "success" && e.issue) {
      const startEpoch = startEpochs[e.issue];
      if (startEpoch && startEpoch > 0) {
        const endEpoch = e.ts_epoch || 0;
        if (endEpoch > startEpoch) {
          leadTimes.push((endEpoch - startEpoch) / 3600); // hours
        }
      }
    }
  }
  const avgLeadTime =
    leadTimes.length > 0
      ? Math.round(
          (leadTimes.reduce((a, b) => a + b, 0) / leadTimes.length) * 100,
        ) / 100
      : 0;

  let leadGrade: DoraMetric["grade"];
  if (leadTimes.length === 0) leadGrade = "Low";
  else if (avgLeadTime < 1) leadGrade = "Elite";
  else if (avgLeadTime < 24) leadGrade = "High";
  else if (avgLeadTime < 168) leadGrade = "Medium";
  else leadGrade = "Low";

  // --- Change Failure Rate ---
  let totalCompleted = 0;
  let totalFailed = 0;
  for (const e of recent) {
    if (e.type === "pipeline.completed") {
      if (e.result === "success") totalCompleted++;
      else totalFailed++;
    }
  }
  const total = totalCompleted + totalFailed;
  const cfr = total > 0 ? Math.round((totalFailed / total) * 10000) / 100 : 0;

  let cfrGrade: DoraMetric["grade"];
  if (total === 0) cfrGrade = "Low";
  else if (cfr < 5) cfrGrade = "Elite";
  else if (cfr < 10) cfrGrade = "High";
  else if (cfr < 15) cfrGrade = "Medium";
  else cfrGrade = "Low";

  // --- Mean Time to Recovery ---
  // For each issue that failed, find time between failure and next success
  const recoveryTimes: number[] = [];
  // Track the most recent failure epoch per issue
  const failureEpochs: Record<number, number> = {};
  for (const e of recent) {
    if (!e.issue) continue;
    if (e.type === "pipeline.completed" && e.result !== "success") {
      failureEpochs[e.issue] = e.ts_epoch || 0;
    }
    if (e.type === "pipeline.completed" && e.result === "success") {
      const failEpoch = failureEpochs[e.issue];
      if (failEpoch && failEpoch > 0) {
        const recoverEpoch = e.ts_epoch || 0;
        if (recoverEpoch > failEpoch) {
          recoveryTimes.push((recoverEpoch - failEpoch) / 3600); // hours
        }
        delete failureEpochs[e.issue];
      }
    }
  }
  const avgMttr =
    recoveryTimes.length > 0
      ? Math.round(
          (recoveryTimes.reduce((a, b) => a + b, 0) / recoveryTimes.length) *
            100,
        ) / 100
      : 0;

  let mttrGrade: DoraMetric["grade"];
  if (recoveryTimes.length === 0) mttrGrade = "Elite";
  else if (avgMttr < 1) mttrGrade = "Elite";
  else if (avgMttr < 24) mttrGrade = "High";
  else if (avgMttr < 168) mttrGrade = "Medium";
  else mttrGrade = "Low";

  return {
    deploy_freq: { value: deploysPerDay, unit: "per day", grade: deployGrade },
    lead_time: { value: avgLeadTime, unit: "hours", grade: leadGrade },
    cfr: { value: cfr, unit: "%", grade: cfrGrade },
    mttr: { value: avgMttr, unit: "hours", grade: mttrGrade },
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
  active_workers: number;
  registered_at: string;
  ssh_user?: string;
  shipwright_path?: string;
  status: "online" | "degraded" | "offline";
  health: {
    daemon_running: boolean;
    heartbeat_count: number;
    last_heartbeat_s_ago: number;
  };
  join_token?: string;
}

interface MachinesFileData {
  machines: Array<Record<string, unknown>>;
}

const JOIN_TOKENS_FILE = join(HOME, ".shipwright", "join-tokens.json");
const MACHINE_HEALTH_FILE = join(HOME, ".shipwright", "machine-health.json");

function readMachinesFile(): MachinesFileData {
  const raw = readFileOr(MACHINES_FILE, '{"machines":[]}');
  try {
    const data = JSON.parse(raw);
    return { machines: data.machines || [] };
  } catch {
    return { machines: [] };
  }
}

function writeMachinesFile(data: MachinesFileData): void {
  const dir = join(HOME, ".shipwright");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const tmp = MACHINES_FILE + ".tmp";
  writeFileSync(tmp, JSON.stringify(data, null, 2), "utf-8");
  renameSync(tmp, MACHINES_FILE);
}

function enrichMachineHealth(
  machine: Record<string, unknown>,
  agents: AgentInfo[],
): MachineInfo {
  const name = (machine.name as string) || "";
  const host = (machine.host as string) || "";
  const activeWorkers = agents.filter(
    (a) => a.machine === name || a.machine === host,
  ).length;

  // Read health data if available
  let daemonRunning = false;
  let heartbeatCount = 0;
  let lastHeartbeatSAgo = 9999;

  try {
    if (existsSync(MACHINE_HEALTH_FILE)) {
      const healthData = JSON.parse(readFileSync(MACHINE_HEALTH_FILE, "utf-8"));
      const mHealth = healthData[name] || healthData[host];
      if (mHealth) {
        daemonRunning = !!mHealth.daemon_running;
        heartbeatCount = (mHealth.heartbeat_count as number) || 0;
        if (mHealth.last_check) {
          const checkEpoch = Math.floor(
            new Date(mHealth.last_check as string).getTime() / 1000,
          );
          lastHeartbeatSAgo = Math.floor(Date.now() / 1000) - checkEpoch;
        }
      }
    }
  } catch {
    // ignore health read errors
  }

  // Also check heartbeat files for this machine
  const machineHeartbeats = agents.filter(
    (a) => a.machine === name || a.machine === host,
  );
  if (machineHeartbeats.length > 0) {
    heartbeatCount = machineHeartbeats.length;
    const minAge = Math.min(...machineHeartbeats.map((a) => a.heartbeat_age_s));
    if (minAge < lastHeartbeatSAgo) lastHeartbeatSAgo = minAge;
  }

  let status: MachineInfo["status"] = "offline";
  if (lastHeartbeatSAgo < 60) status = "online";
  else if (lastHeartbeatSAgo < 300 || daemonRunning) status = "degraded";

  return {
    name,
    host,
    role: (machine.role as string) || "worker",
    max_workers: (machine.max_workers as number) || 4,
    active_workers: activeWorkers,
    registered_at: (machine.registered_at as string) || "",
    ssh_user: (machine.ssh_user as string) || undefined,
    shipwright_path: (machine.shipwright_path as string) || undefined,
    status,
    health: {
      daemon_running: daemonRunning,
      heartbeat_count: heartbeatCount,
      last_heartbeat_s_ago: lastHeartbeatSAgo,
    },
    join_token: (machine.join_token as string) || undefined,
  };
}

function getMachines(): MachineInfo[] {
  const data = readMachinesFile();
  if (data.machines.length === 0) return [];
  const agents = getAgents();
  return data.machines.map((m) => enrichMachineHealth(m, agents));
}

function generateJoinScript(
  token: string,
  dashboardUrl: string,
  maxWorkers: number,
): string {
  return `#!/usr/bin/env bash
set -euo pipefail
# Shipwright remote worker join script
# Generated by Shipwright Dashboard

DASHBOARD_URL="${dashboardUrl}"
JOIN_TOKEN="${token}"
MAX_WORKERS="${maxWorkers}"

echo "==> Joining Shipwright cluster..."
echo "    Dashboard: \${DASHBOARD_URL}"
echo "    Max workers: \${MAX_WORKERS}"

# Verify shipwright is installed
if ! command -v shipwright &>/dev/null && ! command -v sw &>/dev/null; then
  echo "ERROR: shipwright not found in PATH"
  echo "Install: curl -fsSL https://raw.githubusercontent.com/sethdford/shipwright/main/install.sh | bash"
  exit 1
fi

SW=\$(command -v shipwright || command -v sw)

# Register this machine with the dashboard
HOSTNAME=\$(hostname)
\$SW remote add "\${HOSTNAME}" \\
  --host "\$(hostname -f 2>/dev/null || hostname)" \\
  --max-workers "\${MAX_WORKERS}" \\
  --join-token "\${JOIN_TOKEN}" 2>/dev/null || true

echo "==> Machine registered. Starting daemon..."
\$SW daemon start --max-parallel "\${MAX_WORKERS}"
`;
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
  const configPath = join(HOME, ".shipwright", "tracker-config.json");
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

// ─── GitHub CLI Cache ────────────────────────────────────────────────
const ghCache = new Map<string, { data: unknown; ts: number }>();
const GH_CACHE_TTL_MS = 30_000;

function ghCached<T>(key: string, fn: () => T): T {
  const now = Date.now();
  const cached = ghCache.get(key);
  if (cached && now - cached.ts < GH_CACHE_TTL_MS) return cached.data as T;
  const data = fn();
  ghCache.set(key, { data, ts: now });
  return data;
}

// ─── Memory System Helpers ──────────────────────────────────────────
function readMemoryFiles(filename: string): unknown[] {
  if (!existsSync(MEMORY_DIR)) return [];
  const results: unknown[] = [];
  try {
    const subdirs = readdirSync(MEMORY_DIR);
    for (const sub of subdirs) {
      const filePath = join(MEMORY_DIR, sub, filename);
      if (existsSync(filePath)) {
        try {
          const content = readFileSync(filePath, "utf-8");
          const parsed = JSON.parse(content);
          if (Array.isArray(parsed)) results.push(...parsed);
          else results.push(parsed);
        } catch {
          // skip malformed files
        }
      }
    }
  } catch {
    // ignore
  }
  return results;
}

function stripAnsi(content: string): string {
  return content.replace(/\x1b\[[0-9;]*m/g, "");
}

// ─── Model Pricing (per 1M tokens) ──────────────────────────────────
const MODEL_PRICING: Record<string, { input: number; output: number }> = {
  opus: { input: 15, output: 75 },
  sonnet: { input: 3, output: 15 },
  haiku: { input: 0.25, output: 1.25 },
};

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
  const watchDir = join(HOME, ".shipwright");
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
    if (match) {
      sessions.delete(match[1]);
      saveSessions();
    }
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
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
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

    // GET /api/join/{token} — Serve join script (public, no auth required)
    if (pathname.startsWith("/api/join/") && req.method === "GET") {
      const token = pathname.split("/")[3] || "";
      if (!token) {
        return new Response("Missing token", { status: 400 });
      }
      try {
        let tokens: Array<Record<string, unknown>> = [];
        try {
          if (existsSync(JOIN_TOKENS_FILE)) {
            tokens = JSON.parse(readFileSync(JOIN_TOKENS_FILE, "utf-8"));
          }
        } catch {
          tokens = [];
        }
        const entry = tokens.find((t) => (t.token as string) === token);
        if (!entry) {
          return new Response(
            "#!/usr/bin/env bash\necho 'ERROR: Invalid or expired join token'\nexit 1\n",
            {
              headers: { "Content-Type": "text/plain", ...CORS_HEADERS },
            },
          );
        }
        const dashboardUrl = `${url.protocol}//${url.host}`;
        const maxWorkers = (entry.max_workers as number) || 4;
        const script = generateJoinScript(token, dashboardUrl, maxWorkers);

        // Mark token as used
        entry.used = true;
        entry.used_at = new Date().toISOString();
        const dir = join(HOME, ".shipwright");
        if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
        const tokensTmp = JOIN_TOKENS_FILE + ".tmp";
        writeFileSync(tokensTmp, JSON.stringify(tokens, null, 2), "utf-8");
        renameSync(tokensTmp, JOIN_TOKENS_FILE);

        return new Response(script, {
          headers: { "Content-Type": "text/plain", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(
          `#!/usr/bin/env bash\necho 'ERROR: ${String(err)}'\nexit 1\n`,
          {
            status: 500,
            headers: { "Content-Type": "text/plain", ...CORS_HEADERS },
          },
        );
      }
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
      const period = parseInt(url.searchParams.get("period") || "7");
      const doraPeriod = period > 0 && period <= 365 ? period : 7;
      return new Response(JSON.stringify(getMetricsHistory(doraPeriod)), {
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

    // REST: Bulk intervention (must be before generic /api/intervention/)
    if (pathname === "/api/intervention/bulk" && req.method === "POST") {
      try {
        const body = (await req.json()) as {
          issues: number[];
          action: string;
        };
        const { issues, action } = body;
        if (!Array.isArray(issues) || !action) {
          return new Response(
            JSON.stringify({ error: "Missing issues array or action" }),
            {
              status: 400,
              headers: { "Content-Type": "application/json", ...CORS_HEADERS },
            },
          );
        }

        const dState = readDaemonState();
        const activeJobsList = dState
          ? (dState.active_jobs as Array<Record<string, unknown>>) || []
          : [];

        const results: Array<{ issue: number; ok: boolean; error?: string }> =
          [];
        for (const issueNum of issues) {
          try {
            let pid: number | null = null;
            for (const job of activeJobsList) {
              if ((job.issue as number) === issueNum) {
                pid = (job.pid as number) || null;
                break;
              }
            }
            if (!pid) {
              results.push({
                issue: issueNum,
                ok: false,
                error: "No active PID found",
              });
              continue;
            }
            switch (action) {
              case "pause":
                execSync(`kill -STOP ${pid}`);
                break;
              case "resume":
                execSync(`kill -CONT ${pid}`);
                break;
              case "abort":
                execSync(`kill -TERM ${pid}`);
                break;
              default:
                results.push({
                  issue: issueNum,
                  ok: false,
                  error: `Unknown action: ${action}`,
                });
                continue;
            }
            results.push({ issue: issueNum, ok: true });
          } catch (err) {
            results.push({
              issue: issueNum,
              ok: false,
              error: String(err),
            });
          }
        }

        return new Response(JSON.stringify({ results }), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
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

    // ── Phase 1: Pipeline Deep-Dive endpoints ─────────────────────

    // REST: Pipeline build logs
    if (pathname.startsWith("/api/logs/")) {
      const issueNum = parseInt(pathname.split("/")[3] || "0");
      if (!issueNum || isNaN(issueNum)) {
        return new Response(JSON.stringify({ error: "Invalid issue number" }), {
          status: 400,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
      const logFile = join(LOGS_DIR, `issue-${issueNum}.log`);
      const raw = readFileOr(logFile, "");
      return new Response(JSON.stringify({ content: stripAnsi(raw) }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Pipeline artifacts (plan, design, dod, test-results, review, coverage)
    if (pathname.startsWith("/api/artifacts/")) {
      const parts = pathname.split("/");
      const issueNum = parseInt(parts[3] || "0");
      const artifactType = parts[4] || "";
      if (!issueNum || isNaN(issueNum) || !artifactType) {
        return new Response(
          JSON.stringify({ error: "Invalid issue or artifact type" }),
          {
            status: 400,
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      }
      const worktreeBase = findWorktreeBase(issueNum);
      let content = "";
      let fileType = "md";
      if (worktreeBase) {
        const artifactsDir = join(
          worktreeBase,
          ".claude",
          "pipeline-artifacts",
        );
        // Try .md, .log, .json extensions
        for (const ext of [".md", ".log", ".json"]) {
          const filePath = join(artifactsDir, `${artifactType}${ext}`);
          if (existsSync(filePath)) {
            content = readFileOr(filePath, "");
            fileType = ext.slice(1);
            break;
          }
        }
      }
      return new Response(JSON.stringify({ content, type: fileType }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: GitHub issue + PR info
    if (pathname.startsWith("/api/github/")) {
      const issueNum = parseInt(pathname.split("/")[3] || "0");
      if (!issueNum || isNaN(issueNum)) {
        return new Response(JSON.stringify({ error: "Invalid issue number" }), {
          status: 400,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
      const data = ghCached(`github-${issueNum}`, () => {
        try {
          const issueRaw = execSync(
            `gh issue view ${issueNum} --json title,state,labels,assignees,url`,
            { encoding: "utf-8", timeout: 10000 },
          );
          const prRaw = execSync(
            `gh pr list --search "issue-${issueNum}" --json number,state,url,statusCheckRollup,reviews`,
            { encoding: "utf-8", timeout: 10000 },
          );
          const issue = JSON.parse(issueRaw);
          const prs = JSON.parse(prRaw) as Array<Record<string, unknown>>;
          const pr = prs.length > 0 ? prs[0] : null;
          const checks = pr
            ? (
                (pr.statusCheckRollup as Array<Record<string, string>>) || []
              ).map((c) => ({
                name: c.name || c.context || "",
                status: (c.conclusion || c.state || "pending").toLowerCase(),
              }))
            : [];
          return {
            configured: true,
            issue_title: issue.title || "",
            issue_state: (issue.state || "").toLowerCase(),
            issue_url: issue.url || "",
            pr_number: pr ? (pr.number as number) : null,
            pr_state: pr ? ((pr.state as string) || "").toLowerCase() : null,
            pr_url: pr ? (pr.url as string) || "" : null,
            checks,
          };
        } catch {
          return { configured: false };
        }
      });
      return new Response(JSON.stringify(data), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Events filtered by issue
    if (pathname.startsWith("/api/events/")) {
      const issueNum = parseInt(pathname.split("/")[3] || "0");
      if (!issueNum || isNaN(issueNum)) {
        return new Response(JSON.stringify({ error: "Invalid issue number" }), {
          status: 400,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
      const allEvents = readEvents();
      const filtered = allEvents.filter((e) => e.issue === issueNum);
      return new Response(JSON.stringify({ events: filtered }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // ── SQLite DB API endpoints ─────────────────────────────────────

    // REST: Events from DB with since/limit params
    if (pathname === "/api/db/events") {
      const since = parseInt(url.searchParams.get("since") || "0");
      const limit = Math.min(
        parseInt(url.searchParams.get("limit") || "200"),
        10000,
      );
      const events = dbQueryEvents(since, limit);
      return new Response(
        JSON.stringify({
          events,
          source: events.length > 0 ? "sqlite" : "none",
        }),
        {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        },
      );
    }

    // REST: Active/completed jobs from DB
    if (pathname === "/api/db/jobs") {
      const status = url.searchParams.get("status") || undefined;
      const jobs = dbQueryJobs(status);
      return new Response(
        JSON.stringify({ jobs, source: jobs.length > 0 ? "sqlite" : "none" }),
        {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        },
      );
    }

    // REST: Today's cost from DB
    if (pathname === "/api/db/costs/today") {
      const costs = dbQueryCostsToday();
      return new Response(JSON.stringify({ ...costs, source: "sqlite" }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Heartbeats from DB
    if (pathname === "/api/db/heartbeats") {
      const heartbeats = dbQueryHeartbeats();
      return new Response(
        JSON.stringify({
          heartbeats,
          source: heartbeats.length > 0 ? "sqlite" : "none",
        }),
        {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        },
      );
    }

    // REST: DB health info
    if (pathname === "/api/db/health") {
      const conn = getDb();
      if (!conn) {
        return new Response(JSON.stringify({ available: false }), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
      try {
        const version = conn
          .query("SELECT MAX(version) as v FROM _schema")
          .get() as { v: number } | null;
        const walMode = conn.query("PRAGMA journal_mode").get() as {
          journal_mode: string;
        } | null;
        const eventCount = conn
          .query("SELECT COUNT(*) as c FROM events")
          .get() as { c: number } | null;
        const runCount = conn
          .query("SELECT COUNT(*) as c FROM pipeline_runs")
          .get() as { c: number } | null;
        const costCount = conn
          .query("SELECT COUNT(*) as c FROM cost_entries")
          .get() as { c: number } | null;

        return new Response(
          JSON.stringify({
            available: true,
            schema_version: version?.v || 0,
            wal_mode: walMode?.journal_mode || "unknown",
            events: eventCount?.c || 0,
            runs: runCount?.c || 0,
            costs: costCount?.c || 0,
          }),
          { headers: { "Content-Type": "application/json", ...CORS_HEADERS } },
        );
      } catch {
        return new Response(
          JSON.stringify({ available: false, error: "query failed" }),
          {
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      }
    }

    // REST: Memory failure patterns for a specific issue
    if (pathname.startsWith("/api/memory/failures/")) {
      const issueNum = parseInt(pathname.split("/")[4] || "0");
      if (!issueNum || isNaN(issueNum)) {
        return new Response(JSON.stringify({ error: "Invalid issue number" }), {
          status: 400,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
      const allPatterns = readMemoryFiles("failures.json") as Array<
        Record<string, unknown>
      >;
      const matched = allPatterns.filter((p) => {
        const issues = (p.issues as number[]) || [];
        const issue = p.issue as number;
        return issues.includes(issueNum) || issue === issueNum;
      });
      return new Response(JSON.stringify({ patterns: matched }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // ── Phase 2: Queue Intelligence + Cost Analytics ─────────────

    // REST: Detailed queue with triage scores
    if (pathname === "/api/queue/detailed") {
      const daemonState = readDaemonState();
      const events = readEvents();
      const queued = daemonState
        ? (daemonState.queued as Array<number | Record<string, unknown>>) || []
        : [];

      // Build triage score map from most recent daemon.triage events
      const triageMap: Record<number, Record<string, unknown>> = {};
      for (const e of events) {
        if (e.type === "daemon.triage" && e.issue) {
          triageMap[e.issue] = {
            complexity: e.complexity,
            impact: e.impact,
            priority: e.priority,
            age: e.age,
            dependency: e.dependency,
            memory: e.memory,
            score: e.score,
          };
        }
      }

      const enriched = queued.map((q) => {
        const issue = typeof q === "number" ? q : (q.issue as number) || 0;
        const title = typeof q === "number" ? "" : (q.title as string) || "";
        const score = typeof q === "number" ? 0 : (q.score as number) || 0;
        const triage = triageMap[issue] || {};
        return { issue, title, score, ...triage };
      });

      return new Response(JSON.stringify({ queue: enriched }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Cost breakdown by stage, model, issue
    if (pathname === "/api/costs/breakdown") {
      const period = parseInt(url.searchParams.get("period") || "7");
      const events = readEvents();
      const now = Math.floor(Date.now() / 1000);
      const cutoff = now - period * 86400;

      const byStage: Record<string, number> = {};
      const byModel: Record<string, number> = {};
      const byIssue: Record<number, number> = {};
      let total = 0;

      for (const e of events) {
        if ((e.ts_epoch || 0) < cutoff) continue;
        if (e.type !== "pipeline.cost" && e.type !== "cost.record") continue;

        let cost = (e.cost_usd as number) || 0;
        if (!cost) {
          // Calculate from tokens if cost not directly recorded
          const inputTokens = (e.input_tokens as number) || 0;
          const outputTokens = (e.output_tokens as number) || 0;
          const model = ((e.model as string) || "sonnet").toLowerCase();
          const pricing = MODEL_PRICING[model] || MODEL_PRICING["sonnet"];
          cost =
            (inputTokens / 1_000_000) * pricing.input +
            (outputTokens / 1_000_000) * pricing.output;
        }

        if (cost <= 0) continue;
        total += cost;

        const stage = (e.stage as string) || "unknown";
        byStage[stage] = (byStage[stage] || 0) + cost;

        const model = (e.model as string) || "unknown";
        byModel[model] = (byModel[model] || 0) + cost;

        if (e.issue) {
          byIssue[e.issue] = (byIssue[e.issue] || 0) + cost;
        }
      }

      // Round all values
      for (const k of Object.keys(byStage))
        byStage[k] = Math.round(byStage[k] * 100) / 100;
      for (const k of Object.keys(byModel))
        byModel[k] = Math.round(byModel[k] * 100) / 100;
      for (const k of Object.keys(byIssue))
        byIssue[parseInt(k)] = Math.round(byIssue[parseInt(k)] * 100) / 100;

      return new Response(
        JSON.stringify({
          byStage,
          byModel,
          byIssue,
          total: Math.round(total * 100) / 100,
        }),
        { headers: { "Content-Type": "application/json", ...CORS_HEADERS } },
      );
    }

    // REST: Cost trend (daily aggregation)
    if (pathname === "/api/costs/trend") {
      const period = parseInt(url.searchParams.get("period") || "30");
      const events = readEvents();
      const now = Math.floor(Date.now() / 1000);
      const cutoff = now - period * 86400;

      const dailyMap: Record<string, number> = {};
      // Initialize all days
      for (let i = period - 1; i >= 0; i--) {
        const d = new Date((now - i * 86400) * 1000);
        dailyMap[d.toISOString().split("T")[0]] = 0;
      }

      for (const e of events) {
        if ((e.ts_epoch || 0) < cutoff) continue;
        if (e.type !== "pipeline.cost" && e.type !== "cost.record") continue;
        let cost = (e.cost_usd as number) || 0;
        if (!cost) {
          const inputTokens = (e.input_tokens as number) || 0;
          const outputTokens = (e.output_tokens as number) || 0;
          const model = ((e.model as string) || "sonnet").toLowerCase();
          const pricing = MODEL_PRICING[model] || MODEL_PRICING["sonnet"];
          cost =
            (inputTokens / 1_000_000) * pricing.input +
            (outputTokens / 1_000_000) * pricing.output;
        }
        if (cost <= 0) continue;
        const dateKey = (e.ts || "").split("T")[0];
        if (dateKey in dailyMap) {
          dailyMap[dateKey] += cost;
        }
      }

      const daily = Object.entries(dailyMap)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([date, cost]) => ({ date, cost: Math.round(cost * 100) / 100 }));

      return new Response(JSON.stringify({ daily }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: DORA trend (weekly sliding windows)
    if (pathname === "/api/metrics/dora-trend") {
      const period = parseInt(url.searchParams.get("period") || "30");
      const events = readEvents();
      const weeks: Array<{ week: string; grades: DoraGrades }> = [];

      // Create weekly windows
      const now = Math.floor(Date.now() / 1000);
      const numWeeks = Math.ceil(period / 7);
      for (let i = numWeeks - 1; i >= 0; i--) {
        const weekEnd = now - i * 7 * 86400;
        const weekStart = weekEnd - 7 * 86400;
        const weekEvents = events.filter(
          (e) => (e.ts_epoch || 0) >= weekStart && (e.ts_epoch || 0) < weekEnd,
        );
        const weekDate = new Date(weekEnd * 1000).toISOString().split("T")[0];
        weeks.push({
          week: weekDate,
          grades: calculateDoraGrades(weekEvents, 7),
        });
      }

      return new Response(JSON.stringify({ weeks }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // ── Phase 3: Memory + Patrol + Failure Heatmap ──────────────

    // REST: All memory failure patterns aggregated
    if (pathname === "/api/memory/patterns") {
      const allPatterns = readMemoryFiles("failures.json") as Array<
        Record<string, unknown>
      >;
      // Aggregate by pattern signature (error message or pattern field)
      const freqMap: Record<
        string,
        { pattern: string; frequency: number; rootCause: string; fix: string }
      > = {};
      for (const p of allPatterns) {
        const key = (p.pattern as string) || (p.error as string) || "unknown";
        if (!freqMap[key]) {
          freqMap[key] = {
            pattern: key,
            frequency: 0,
            rootCause:
              (p.root_cause as string) || (p.rootCause as string) || "",
            fix: (p.fix as string) || (p.resolution as string) || "",
          };
        }
        freqMap[key].frequency++;
      }
      const patterns = Object.values(freqMap).sort(
        (a, b) => b.frequency - a.frequency,
      );
      return new Response(JSON.stringify({ patterns }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Memory decisions
    if (pathname === "/api/memory/decisions") {
      const decisions = readMemoryFiles("decisions.json");
      return new Response(JSON.stringify({ decisions }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Global memory/learnings
    if (pathname === "/api/memory/global") {
      const globalPath = join(MEMORY_DIR, "global.json");
      let learnings: unknown[] = [];
      if (existsSync(globalPath)) {
        try {
          const data = JSON.parse(readFileSync(globalPath, "utf-8"));
          learnings = Array.isArray(data) ? data : data.learnings || [];
        } catch {
          // ignore
        }
      }
      return new Response(JSON.stringify({ learnings }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Recent patrol findings
    if (pathname === "/api/patrol/recent") {
      const events = readEvents();
      const findings: DaemonEvent[] = [];
      const runs: DaemonEvent[] = [];
      for (const e of events) {
        if (e.type === "patrol.finding") findings.push(e);
        if (e.type === "patrol.completed") runs.push(e);
      }
      return new Response(
        JSON.stringify({
          findings: findings.slice(-50),
          runs: runs.slice(-20),
        }),
        { headers: { "Content-Type": "application/json", ...CORS_HEADERS } },
      );
    }

    // REST: Failure heatmap (stage x day)
    if (pathname === "/api/metrics/failure-heatmap") {
      const events = readEvents();
      const heatmap: Record<string, Record<string, number>> = {};
      for (const e of events) {
        if (e.type !== "stage.failed") continue;
        const stage = e.stage || "unknown";
        const date = (e.ts || "").split("T")[0];
        if (!date) continue;
        if (!heatmap[stage]) heatmap[stage] = {};
        heatmap[stage][date] = (heatmap[stage][date] || 0) + 1;
      }
      return new Response(JSON.stringify({ heatmap }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // ── Phase 4: Performance Analytics ──────────────────────────

    // REST: Per-stage performance stats
    if (pathname === "/api/metrics/stage-performance") {
      const period = parseInt(url.searchParams.get("period") || "7");
      const events = readEvents();
      const now = Math.floor(Date.now() / 1000);
      const cutoff = now - period * 86400;
      const halfCutoff = now - Math.floor(period / 2) * 86400;

      const stageData: Record<
        string,
        {
          durations: number[];
          costs: number[];
          firstHalf: number[];
          secondHalf: number[];
        }
      > = {};

      for (const e of events) {
        if ((e.ts_epoch || 0) < cutoff) continue;
        if (e.type === "stage.completed" && e.stage) {
          const stage = e.stage;
          if (!stageData[stage]) {
            stageData[stage] = {
              durations: [],
              costs: [],
              firstHalf: [],
              secondHalf: [],
            };
          }
          const dur = e.duration_s || 0;
          stageData[stage].durations.push(dur);
          if ((e.ts_epoch || 0) < halfCutoff) {
            stageData[stage].firstHalf.push(dur);
          } else {
            stageData[stage].secondHalf.push(dur);
          }
          const cost = (e.cost_usd as number) || 0;
          if (cost > 0) stageData[stage].costs.push(cost);
        }
      }

      const stages = Object.entries(stageData).map(([name, data]) => {
        const sum = data.durations.reduce((a, b) => a + b, 0);
        const avg = data.durations.length > 0 ? sum / data.durations.length : 0;
        const firstAvg =
          data.firstHalf.length > 0
            ? data.firstHalf.reduce((a, b) => a + b, 0) / data.firstHalf.length
            : avg;
        const secondAvg =
          data.secondHalf.length > 0
            ? data.secondHalf.reduce((a, b) => a + b, 0) /
              data.secondHalf.length
            : avg;
        const trend =
          firstAvg > 0
            ? Math.round(((secondAvg - firstAvg) / firstAvg) * 100)
            : 0;
        const costSum = data.costs.reduce((a, b) => a + b, 0);

        return {
          name,
          avgDuration: Math.round(avg),
          minDuration: Math.min(...data.durations),
          maxDuration: Math.max(...data.durations),
          count: data.durations.length,
          cost: Math.round(costSum * 100) / 100,
          trend,
        };
      });

      return new Response(JSON.stringify({ stages }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Bottleneck analysis
    if (pathname === "/api/metrics/bottlenecks") {
      const events = readEvents();
      const now = Math.floor(Date.now() / 1000);
      const cutoff = now - 7 * 86400;

      const stageDurs: Record<string, number[]> = {};
      for (const e of events) {
        if ((e.ts_epoch || 0) < cutoff) continue;
        if (e.type === "stage.completed" && e.stage) {
          if (!stageDurs[e.stage]) stageDurs[e.stage] = [];
          stageDurs[e.stage].push(e.duration_s || 0);
        }
      }

      const bottlenecks = Object.entries(stageDurs)
        .map(([stage, durs]) => {
          const avg = durs.reduce((a, b) => a + b, 0) / durs.length;
          return { stage, avgDuration: Math.round(avg), count: durs.length };
        })
        .sort((a, b) => b.avgDuration - a.avgDuration)
        .slice(0, 5)
        .map((b) => ({
          stage: b.stage,
          avgDuration: b.avgDuration,
          impact:
            b.avgDuration > 600
              ? "high"
              : b.avgDuration > 300
                ? "medium"
                : "low",
          suggestion:
            b.avgDuration > 600
              ? `${b.stage} averages ${Math.round(b.avgDuration / 60)}min — consider parallelization or caching`
              : b.avgDuration > 300
                ? `${b.stage} is moderately slow — review for optimization opportunities`
                : `${b.stage} is performing well`,
        }));

      return new Response(JSON.stringify({ bottlenecks }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Throughput trend (issues per hour, daily)
    if (pathname === "/api/metrics/throughput-trend") {
      const period = parseInt(url.searchParams.get("period") || "30");
      const events = readEvents();
      const now = Math.floor(Date.now() / 1000);
      const cutoff = now - period * 86400;

      const dailyMap: Record<string, number> = {};
      for (let i = period - 1; i >= 0; i--) {
        const d = new Date((now - i * 86400) * 1000);
        dailyMap[d.toISOString().split("T")[0]] = 0;
      }

      for (const e of events) {
        if ((e.ts_epoch || 0) < cutoff) continue;
        if (e.type === "pipeline.completed" && e.result === "success") {
          const dateKey = (e.ts || "").split("T")[0];
          if (dateKey in dailyMap) dailyMap[dateKey]++;
        }
      }

      const daily = Object.entries(dailyMap)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([date, count]) => ({
          date,
          throughput: Math.round((count / 24) * 100) / 100,
        }));

      return new Response(JSON.stringify({ daily }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Capacity estimation
    if (pathname === "/api/metrics/capacity") {
      const daemonState = readDaemonState();
      const events = readEvents();
      const now = Math.floor(Date.now() / 1000);

      // Queue depth
      const queued = daemonState
        ? ((daemonState.queued as Array<unknown>) || []).length
        : 0;

      // Calculate current rate (completions per hour in last 24h)
      const oneDayAgo = now - 86400;
      let completedLast24h = 0;
      for (const e of events) {
        if (
          e.type === "pipeline.completed" &&
          e.result === "success" &&
          (e.ts_epoch || 0) >= oneDayAgo
        ) {
          completedLast24h++;
        }
      }
      const currentRate = Math.round((completedLast24h / 24) * 100) / 100;
      const estimatedClearTime =
        currentRate > 0
          ? `${Math.round(queued / currentRate)}h`
          : queued > 0
            ? "unknown"
            : "0h";

      return new Response(
        JSON.stringify({
          queueDepth: queued,
          currentRate,
          estimatedClearTime,
        }),
        { headers: { "Content-Type": "application/json", ...CORS_HEADERS } },
      );
    }

    // ── Phase 5: Alerts + Bulk Actions + Emergency ──────────────

    // REST: Computed alerts
    if (pathname === "/api/alerts") {
      const events = readEvents();
      const daemonState = readDaemonState();
      const costInfo = getCostInfo();
      const now = Math.floor(Date.now() / 1000);
      const alerts: Array<{
        type: string;
        severity: string;
        message: string;
        issue?: number;
        actions?: string[];
      }> = [];

      // Stuck pipelines: no stage change > 30min
      if (daemonState) {
        const activeJobs =
          (daemonState.active_jobs as Array<Record<string, unknown>>) || [];
        for (const job of activeJobs) {
          const issue = (job.issue as number) || 0;
          // Find most recent stage event for this issue
          let lastStageEpoch = 0;
          for (const e of events) {
            if (
              e.issue === issue &&
              (e.type === "stage.started" || e.type === "stage.completed")
            ) {
              lastStageEpoch = Math.max(lastStageEpoch, e.ts_epoch || 0);
            }
          }
          if (lastStageEpoch > 0 && now - lastStageEpoch > 1800) {
            alerts.push({
              type: "stuck_pipeline",
              severity: "warning",
              message: `Pipeline for issue #${issue} has had no stage change for ${Math.round((now - lastStageEpoch) / 60)}min`,
              issue,
              actions: ["pause", "abort", "message"],
            });
          }
        }
      }

      // Budget warning (>80%)
      if (costInfo.pct_used > 80) {
        alerts.push({
          type: "budget_warning",
          severity: costInfo.pct_used > 95 ? "critical" : "warning",
          message: `Budget usage at ${costInfo.pct_used}% ($${costInfo.today_spent}/$${costInfo.daily_budget})`,
          actions: ["pause_daemon"],
        });
      }

      // Queue depth (>10)
      const queueDepth = daemonState
        ? ((daemonState.queued as Array<unknown>) || []).length
        : 0;
      if (queueDepth > 10) {
        alerts.push({
          type: "queue_depth",
          severity: queueDepth > 20 ? "critical" : "warning",
          message: `Queue depth is ${queueDepth} issues`,
          actions: ["scale_up"],
        });
      }

      // Failure spike (>3 failures/hr)
      const oneHourAgo = now - 3600;
      let failuresLastHour = 0;
      for (const e of events) {
        if (
          e.type === "pipeline.completed" &&
          e.result !== "success" &&
          (e.ts_epoch || 0) >= oneHourAgo
        ) {
          failuresLastHour++;
        }
      }
      if (failuresLastHour > 3) {
        alerts.push({
          type: "failure_spike",
          severity: "critical",
          message: `${failuresLastHour} pipeline failures in the last hour`,
          actions: ["emergency_brake", "review_logs"],
        });
      }

      // Stale heartbeat (>5min)
      if (existsSync(HEARTBEAT_DIR)) {
        try {
          const files = readdirSync(HEARTBEAT_DIR).filter((f) =>
            f.endsWith(".json"),
          );
          for (const file of files) {
            try {
              const hb = JSON.parse(
                readFileSync(join(HEARTBEAT_DIR, file), "utf-8"),
              );
              const updatedAt = hb.updated_at || "";
              let hbEpoch = 0;
              try {
                hbEpoch = Math.floor(new Date(updatedAt).getTime() / 1000);
              } catch {
                /* ignore */
              }
              if (hbEpoch > 0 && now - hbEpoch > 300) {
                const issue = (hb.issue as number) || 0;
                alerts.push({
                  type: "stale_heartbeat",
                  severity: "warning",
                  message: `Agent heartbeat for ${file.replace(".json", "")} is ${Math.round((now - hbEpoch) / 60)}min stale`,
                  issue: issue || undefined,
                  actions: ["abort", "investigate"],
                });
              }
            } catch {
              // skip
            }
          }
        } catch {
          // ignore
        }
      }

      return new Response(JSON.stringify({ alerts }), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // REST: Emergency brake — pause all active pipelines + clear queue
    if (pathname === "/api/emergency-brake" && req.method === "POST") {
      try {
        const daemonState = readDaemonState();
        let paused = 0;
        let queued = 0;

        if (daemonState) {
          const activeJobs =
            (daemonState.active_jobs as Array<Record<string, unknown>>) || [];
          for (const job of activeJobs) {
            const pid = (job.pid as number) || 0;
            if (pid) {
              try {
                execSync(`kill -STOP ${pid}`);
                paused++;
              } catch {
                // process may already be gone
              }
            }
          }
          queued = ((daemonState.queued as Array<unknown>) || []).length;
        }

        return new Response(JSON.stringify({ paused, queued }), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // ── Machine Management endpoints ──────────────────────────────

    // POST /api/machines — Register a new machine
    if (pathname === "/api/machines" && req.method === "POST") {
      try {
        const body = (await req.json()) as Record<string, unknown>;
        const name = (body.name as string) || "";
        const host = (body.host as string) || "";
        if (!name || !host) {
          return new Response(
            JSON.stringify({ error: "name and host are required" }),
            {
              status: 400,
              headers: { "Content-Type": "application/json", ...CORS_HEADERS },
            },
          );
        }
        const data = readMachinesFile();
        if (data.machines.some((m) => (m.name as string) === name)) {
          return new Response(
            JSON.stringify({ error: `Machine "${name}" already exists` }),
            {
              status: 409,
              headers: { "Content-Type": "application/json", ...CORS_HEADERS },
            },
          );
        }
        const newMachine: Record<string, unknown> = {
          name,
          host,
          role: (body.role as string) || "worker",
          max_workers: (body.max_workers as number) || 4,
          ssh_user: (body.ssh_user as string) || undefined,
          shipwright_path: (body.shipwright_path as string) || undefined,
          registered_at: new Date().toISOString(),
        };
        data.machines.push(newMachine);
        writeMachinesFile(data);
        const agents = getAgents();
        return new Response(
          JSON.stringify(enrichMachineHealth(newMachine, agents)),
          {
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // GET /api/machines — List all machines with enriched health
    if (pathname === "/api/machines" && req.method === "GET") {
      return new Response(JSON.stringify(getMachines()), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // PATCH /api/machines/{name} — Scale workers or update fields
    if (
      pathname.startsWith("/api/machines/") &&
      !pathname.includes("/health-check") &&
      req.method === "PATCH"
    ) {
      const machineName = decodeURIComponent(pathname.split("/")[3] || "");
      if (!machineName) {
        return new Response(
          JSON.stringify({ error: "Machine name is required" }),
          {
            status: 400,
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      }
      try {
        const body = (await req.json()) as Record<string, unknown>;
        const data = readMachinesFile();
        const idx = data.machines.findIndex(
          (m) => (m.name as string) === machineName,
        );
        if (idx === -1) {
          return new Response(
            JSON.stringify({ error: `Machine "${machineName}" not found` }),
            {
              status: 400,
              headers: { "Content-Type": "application/json", ...CORS_HEADERS },
            },
          );
        }
        // Update allowed fields
        if (body.max_workers !== undefined)
          data.machines[idx].max_workers = body.max_workers;
        if (body.role !== undefined) data.machines[idx].role = body.role;
        if (body.ssh_user !== undefined)
          data.machines[idx].ssh_user = body.ssh_user;
        if (body.shipwright_path !== undefined)
          data.machines[idx].shipwright_path = body.shipwright_path;

        // If scaling, attempt to send command to remote machine
        if (body.max_workers !== undefined) {
          const machine = data.machines[idx];
          const sshUser = (machine.ssh_user as string) || "";
          const mHost = (machine.host as string) || "";
          const swPath = (machine.shipwright_path as string) || "shipwright";
          if (
            sshUser &&
            mHost &&
            mHost !== "localhost" &&
            mHost !== "127.0.0.1"
          ) {
            try {
              execSync(
                `ssh -o ConnectTimeout=5 ${sshUser}@${mHost} "${swPath} daemon scale ${body.max_workers}" 2>/dev/null`,
                { timeout: 10000 },
              );
            } catch {
              // Remote scale command failed — update saved anyway
            }
          }
        }

        writeMachinesFile(data);
        const agents = getAgents();
        return new Response(
          JSON.stringify(enrichMachineHealth(data.machines[idx], agents)),
          {
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // POST /api/machines/{name}/health-check — On-demand health check
    if (
      pathname.match(/^\/api\/machines\/[^/]+\/health-check$/) &&
      req.method === "POST"
    ) {
      const machineName = decodeURIComponent(pathname.split("/")[3] || "");
      try {
        const data = readMachinesFile();
        const machine = data.machines.find(
          (m) => (m.name as string) === machineName,
        );
        if (!machine) {
          return new Response(
            JSON.stringify({ error: `Machine "${machineName}" not found` }),
            {
              status: 400,
              headers: { "Content-Type": "application/json", ...CORS_HEADERS },
            },
          );
        }

        const sshUser = (machine.ssh_user as string) || "";
        const mHost = (machine.host as string) || "";
        const swPath = (machine.shipwright_path as string) || "shipwright";
        let daemonRunning = false;
        let reachable = false;

        if (!mHost || mHost === "localhost" || mHost === "127.0.0.1") {
          // Local machine — check daemon state directly
          reachable = true;
          try {
            const dState = readFileOr(DAEMON_STATE, "");
            if (dState) {
              const parsed = JSON.parse(dState);
              daemonRunning = !!parsed.pid;
            }
          } catch {
            // ignore
          }
        } else if (sshUser) {
          try {
            const result = execSync(
              `ssh -o ConnectTimeout=5 -o BatchMode=yes ${sshUser}@${mHost} "${swPath} ps 2>/dev/null || echo OFFLINE"`,
              { timeout: 10000, encoding: "utf-8" },
            );
            reachable = true;
            daemonRunning =
              !result.includes("OFFLINE") && !result.includes("No daemon");
          } catch {
            reachable = false;
          }
        }

        // Save health data
        let healthData: Record<string, Record<string, unknown>> = {};
        try {
          if (existsSync(MACHINE_HEALTH_FILE)) {
            healthData = JSON.parse(readFileSync(MACHINE_HEALTH_FILE, "utf-8"));
          }
        } catch {
          // ignore
        }
        healthData[machineName] = {
          daemon_running: daemonRunning,
          reachable,
          last_check: new Date().toISOString(),
        };
        const healthTmp = MACHINE_HEALTH_FILE + ".tmp";
        writeFileSync(healthTmp, JSON.stringify(healthData, null, 2), "utf-8");
        renameSync(healthTmp, MACHINE_HEALTH_FILE);

        const agents = getAgents();
        return new Response(
          JSON.stringify({
            machine: enrichMachineHealth(machine, agents),
            reachable,
            daemon_running: daemonRunning,
            checked_at: new Date().toISOString(),
          }),
          { headers: { "Content-Type": "application/json", ...CORS_HEADERS } },
        );
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // DELETE /api/machines/{name} — Remove a machine
    if (pathname.startsWith("/api/machines/") && req.method === "DELETE") {
      const machineName = decodeURIComponent(pathname.split("/")[3] || "");
      if (!machineName) {
        return new Response(
          JSON.stringify({ error: "Machine name is required" }),
          {
            status: 400,
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      }
      try {
        const data = readMachinesFile();
        const idx = data.machines.findIndex(
          (m) => (m.name as string) === machineName,
        );
        if (idx === -1) {
          return new Response(
            JSON.stringify({ error: `Machine "${machineName}" not found` }),
            {
              status: 400,
              headers: { "Content-Type": "application/json", ...CORS_HEADERS },
            },
          );
        }
        data.machines.splice(idx, 1);
        writeMachinesFile(data);
        return new Response(
          JSON.stringify({ ok: true, removed: machineName }),
          {
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // POST /api/join-token — Generate a join token and command
    if (pathname === "/api/join-token" && req.method === "POST") {
      try {
        const body = (await req.json()) as Record<string, unknown>;
        const maxWorkers = (body.max_workers as number) || 4;
        const label = (body.label as string) || "";
        const token = crypto.randomUUID();
        const dashboardUrl = `${url.protocol}//${url.host}`;

        // Save token
        let tokens: Array<Record<string, unknown>> = [];
        try {
          if (existsSync(JOIN_TOKENS_FILE)) {
            const raw = readFileSync(JOIN_TOKENS_FILE, "utf-8");
            tokens = JSON.parse(raw);
          }
        } catch {
          tokens = [];
        }
        tokens.push({
          token,
          label,
          max_workers: maxWorkers,
          created_at: new Date().toISOString(),
          used: false,
        });
        const tokensTmp = JOIN_TOKENS_FILE + ".tmp";
        writeFileSync(tokensTmp, JSON.stringify(tokens, null, 2), "utf-8");
        renameSync(tokensTmp, JOIN_TOKENS_FILE);

        const joinUrl = `${dashboardUrl}/api/join/${token}`;
        const joinCmd = `curl -fsSL "${joinUrl}" | bash`;

        return new Response(
          JSON.stringify({
            token,
            join_url: joinUrl,
            join_cmd: joinCmd,
            max_workers: maxWorkers,
          }),
          { headers: { "Content-Type": "application/json", ...CORS_HEADERS } },
        );
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // GET /api/join-tokens — List active join tokens
    if (pathname === "/api/join-tokens" && req.method === "GET") {
      try {
        let tokens: Array<Record<string, unknown>> = [];
        try {
          if (existsSync(JOIN_TOKENS_FILE)) {
            tokens = JSON.parse(readFileSync(JOIN_TOKENS_FILE, "utf-8"));
          }
        } catch {
          tokens = [];
        }
        return new Response(JSON.stringify(tokens), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // ── Daemon Control endpoints ─────────────────────────────────

    // POST /api/daemon/start — Start daemon in background
    if (pathname === "/api/daemon/start" && req.method === "POST") {
      try {
        execSync("shipwright daemon start --detach", {
          timeout: 10000,
          stdio: "pipe",
        });
        return new Response(JSON.stringify({ ok: true, action: "started" }), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // POST /api/daemon/stop — Stop daemon by PID
    if (pathname === "/api/daemon/stop" && req.method === "POST") {
      try {
        let pid = 0;
        try {
          if (existsSync(DAEMON_STATE)) {
            const state = JSON.parse(readFileSync(DAEMON_STATE, "utf-8"));
            pid = state.pid || 0;
          }
        } catch {
          // state file may be corrupt
        }
        if (pid > 0) {
          try {
            execSync(`kill -TERM ${pid}`, { timeout: 5000, stdio: "pipe" });
          } catch {
            // process may already be gone
          }
        }
        // Also try the daemon stop command
        try {
          execSync("shipwright daemon stop", { timeout: 10000, stdio: "pipe" });
        } catch {
          // may fail if already stopped
        }
        return new Response(
          JSON.stringify({ ok: true, action: "stopped", pid }),
          {
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // POST /api/daemon/pause — Pause daemon polling
    if (pathname === "/api/daemon/pause" && req.method === "POST") {
      try {
        const flagPath = join(HOME, ".shipwright", "daemon-pause.flag");
        const dir = join(HOME, ".shipwright");
        if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
        writeFileSync(
          flagPath,
          JSON.stringify({ paused: true, at: new Date().toISOString() }),
        );
        return new Response(JSON.stringify({ ok: true, action: "paused" }), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // POST /api/daemon/resume — Resume daemon polling
    if (pathname === "/api/daemon/resume" && req.method === "POST") {
      try {
        const flagPath = join(HOME, ".shipwright", "daemon-pause.flag");
        if (existsSync(flagPath)) {
          unlinkSync(flagPath);
        }
        return new Response(JSON.stringify({ ok: true, action: "resumed" }), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // GET /api/daemon/config — Return daemon configuration
    if (pathname === "/api/daemon/config" && req.method === "GET") {
      try {
        // Look for daemon-config.json in common locations
        const configPaths = [
          join(process.cwd(), ".claude", "daemon-config.json"),
          join(HOME, ".claude", "daemon-config.json"),
        ];
        let config: Record<string, unknown> = {};
        for (const p of configPaths) {
          if (existsSync(p)) {
            config = JSON.parse(readFileSync(p, "utf-8"));
            break;
          }
        }
        // Add budget info
        let budget: Record<string, unknown> = {};
        try {
          if (existsSync(BUDGET_FILE)) {
            budget = JSON.parse(readFileSync(BUDGET_FILE, "utf-8"));
          }
        } catch {
          // no budget set
        }
        // Check pause state
        const pauseFlag = join(HOME, ".shipwright", "daemon-pause.flag");
        const paused = existsSync(pauseFlag);

        return new Response(JSON.stringify({ config, budget, paused }), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // POST /api/daemon/patrol — Trigger a one-off patrol run
    if (pathname === "/api/daemon/patrol" && req.method === "POST") {
      try {
        // Run patrol in background (don't block the response)
        execSync("nohup shipwright daemon patrol --once > /dev/null 2>&1 &", {
          timeout: 5000,
          stdio: "pipe",
          shell: "/bin/bash",
        });
        return new Response(
          JSON.stringify({ ok: true, action: "patrol_triggered" }),
          {
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // ── Multi-Developer Platform endpoints ──────────────────────────

    // POST /api/connect/heartbeat — Update developer presence
    if (pathname === "/api/connect/heartbeat" && req.method === "POST") {
      try {
        const body = (await req.json()) as any;

        // Optional auth: if invite tokens exist, require a valid one
        if (inviteTokens.size > 0) {
          const authToken =
            body.invite_token ||
            (req.headers.get("authorization") || "").replace("Bearer ", "");
          if (authToken) {
            const entry = inviteTokens.get(authToken);
            if (!entry || new Date(entry.expires_at).getTime() < Date.now()) {
              return new Response(
                JSON.stringify({ error: "Invalid or expired invite token" }),
                {
                  status: 403,
                  headers: {
                    "Content-Type": "application/json",
                    ...CORS_HEADERS,
                  },
                },
              );
            }
          }
          // If no token provided but tokens exist, check if developer is already registered
          else {
            const existingKey = `${body.developer_id}@${body.machine_name}`;
            if (!developerRegistry.has(existingKey)) {
              return new Response(
                JSON.stringify({
                  error: "Invite token required for new developers",
                  hint: "Run: shipwright connect join --url <dashboard> --token <token>",
                }),
                {
                  status: 403,
                  headers: {
                    "Content-Type": "application/json",
                    ...CORS_HEADERS,
                  },
                },
              );
            }
          }
        }

        const key = `${body.developer_id}@${body.machine_name}`;

        developerRegistry.set(key, {
          developer_id: body.developer_id,
          machine_name: body.machine_name,
          hostname: body.hostname || body.machine_name,
          platform: body.platform || "unknown",
          last_heartbeat: Date.now(),
          daemon_running: body.daemon_running || false,
          daemon_pid: body.daemon_pid || null,
          active_jobs: body.active_jobs || [],
          queued: body.queued || [],
          events_since: body.events_since || 0,
        });

        // Append incoming events to team events log
        if (body.events && Array.isArray(body.events)) {
          const dir = join(HOME, ".shipwright");
          if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
          const enriched = body.events
            .map((e: any) =>
              JSON.stringify({
                ...e,
                from_developer: body.developer_id,
                from_machine: body.machine_name,
              }),
            )
            .join("\n");
          if (enriched) {
            appendFileSync(TEAM_EVENTS_FILE, enriched + "\n");
          }
        }

        saveDeveloperRegistry();

        // Broadcast updated state to dashboard clients
        if (wsClients.size > 0) {
          broadcastToClients(getFleetState());
        }

        return new Response(
          JSON.stringify({ ok: true, team_size: developerRegistry.size }),
          {
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // POST /api/connect/disconnect — Mark developer offline
    if (pathname === "/api/connect/disconnect" && req.method === "POST") {
      try {
        const body = (await req.json()) as any;
        const key = `${body.developer_id}@${body.machine_name}`;
        const dev = developerRegistry.get(key);
        if (dev) {
          dev.last_heartbeat = 0; // mark as offline immediately
          dev.daemon_running = false;
          dev.daemon_pid = null;
          dev.active_jobs = [];
          developerRegistry.set(key, dev);
          saveDeveloperRegistry();
        }

        if (wsClients.size > 0) {
          broadcastToClients(getFleetState());
        }

        return new Response(JSON.stringify({ ok: true }), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // GET /api/team — Return all connected developers with presence
    if (pathname === "/api/team" && req.method === "GET") {
      return new Response(JSON.stringify(getTeamState()), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    // GET /api/team/activity — Return last 100 team events
    if (pathname === "/api/team/activity" && req.method === "GET") {
      try {
        let events: unknown[] = [];
        if (existsSync(TEAM_EVENTS_FILE)) {
          const lines = readFileSync(TEAM_EVENTS_FILE, "utf-8")
            .trim()
            .split("\n")
            .filter(Boolean);
          const recent = lines.slice(-100);
          events = recent
            .map((line) => {
              try {
                return JSON.parse(line);
              } catch {
                return null;
              }
            })
            .filter(Boolean);
        }
        return new Response(JSON.stringify(events), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // POST /api/claim — Label-based claim coordination
    if (pathname === "/api/claim" && req.method === "POST") {
      try {
        const body = (await req.json()) as any;
        const issue = body.issue as number;
        const machine = (body.machine || body.machine_name) as string;
        const repo = (body.repo as string) || "";

        // Check for existing claimed:* label
        const repoFlag = repo ? ` -R ${repo}` : "";
        let labels = "";
        try {
          labels = execSync(
            `gh issue view ${issue}${repoFlag} --json labels -q '.labels[].name'`,
            {
              encoding: "utf-8",
              timeout: 10000,
              stdio: ["pipe", "pipe", "pipe"],
            },
          ).trim();
        } catch {
          labels = "";
        }

        const claimedLabel = labels
          .split("\n")
          .find((l: string) => l.startsWith("claimed:"));
        if (claimedLabel) {
          return new Response(
            JSON.stringify({
              approved: false,
              claimed_by: claimedLabel.replace("claimed:", ""),
            }),
            {
              headers: { "Content-Type": "application/json", ...CORS_HEADERS },
            },
          );
        }

        // Ensure the claimed label exists (no-op if already created)
        try {
          execSync(
            `gh label create "claimed:${machine}"${repoFlag} --color EDEDED --description "Claimed by ${machine}" --force`,
            { timeout: 10000, stdio: ["pipe", "pipe", "pipe"] },
          );
        } catch {
          /* label may already exist or gh label create not supported — fallback below */
        }

        // Add claimed:<machine> label
        try {
          execSync(
            `gh issue edit ${issue}${repoFlag} --add-label "claimed:${machine}"`,
            {
              timeout: 10000,
              stdio: ["pipe", "pipe", "pipe"],
            },
          );
        } catch {
          return new Response(
            JSON.stringify({ approved: false, error: "Failed to set label" }),
            {
              status: 500,
              headers: { "Content-Type": "application/json", ...CORS_HEADERS },
            },
          );
        }

        return new Response(
          JSON.stringify({ approved: true, claimed_by: machine }),
          {
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      } catch (err) {
        return new Response(
          JSON.stringify({ approved: false, error: String(err) }),
          {
            status: 500,
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      }
    }

    // POST /api/claim/release — Remove claimed:* label from issue
    if (pathname === "/api/claim/release" && req.method === "POST") {
      try {
        const body = (await req.json()) as any;
        const issue = body.issue as number;
        const machine = ((body.machine || body.machine_name) as string) || "";
        const repo = (body.repo as string) || "";

        const repoFlag = repo ? ` -R ${repo}` : "";
        const label = machine ? `claimed:${machine}` : "";

        // Find the actual claimed label if machine not specified
        let targetLabel = label;
        if (!targetLabel) {
          try {
            const labels = execSync(
              `gh issue view ${issue}${repoFlag} --json labels -q '.labels[].name'`,
              {
                encoding: "utf-8",
                timeout: 10000,
                stdio: ["pipe", "pipe", "pipe"],
              },
            ).trim();
            const found = labels
              .split("\n")
              .find((l: string) => l.startsWith("claimed:"));
            targetLabel = found || "";
          } catch {
            /* ignore */
          }
        }

        if (targetLabel) {
          try {
            execSync(
              `gh issue edit ${issue}${repoFlag} --remove-label "${targetLabel}"`,
              {
                timeout: 10000,
                stdio: ["pipe", "pipe", "pipe"],
              },
            );
          } catch {
            /* label may already be removed */
          }
        }

        return new Response(JSON.stringify({ ok: true }), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // POST /api/webhook/ci — Accept CI pipeline events
    if (pathname === "/api/webhook/ci" && req.method === "POST") {
      try {
        const body = (await req.json()) as any;
        const dir = join(HOME, ".shipwright");
        if (!existsSync(dir)) mkdirSync(dir, { recursive: true });

        const event = {
          ...body,
          from_developer: "github-actions",
          from_machine: "ci",
          received_at: new Date().toISOString(),
        };
        appendFileSync(TEAM_EVENTS_FILE, JSON.stringify(event) + "\n");

        // Broadcast to dashboard clients
        if (wsClients.size > 0) {
          broadcastToClients(getFleetState());
        }

        return new Response(JSON.stringify({ ok: true }), {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // POST /api/team/invite — Generate a team invite token
    if (pathname === "/api/team/invite" && req.method === "POST") {
      try {
        const token = crypto.randomUUID();
        const now = new Date();
        const expires = new Date(now.getTime() + 24 * 60 * 60 * 1000); // 24h
        inviteTokens.set(token, {
          token,
          created_at: now.toISOString(),
          expires_at: expires.toISOString(),
        });
        saveInviteTokens();

        const dashboardUrl = `${url.protocol}//${url.host}`;
        const command = `shipwright connect join --url ${dashboardUrl} --token ${token}`;

        return new Response(
          JSON.stringify({ token, command, expires_at: expires.toISOString() }),
          {
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        });
      }
    }

    // GET /api/team/invite/<token> — Verify an invite token
    if (pathname.startsWith("/api/team/invite/") && req.method === "GET") {
      const token = pathname.split("/")[4] || "";
      if (!token) {
        return new Response(
          JSON.stringify({ valid: false, error: "Missing token" }),
          {
            status: 400,
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      }
      const entry = inviteTokens.get(token);
      if (!entry || new Date(entry.expires_at).getTime() < Date.now()) {
        if (entry) {
          inviteTokens.delete(token);
          saveInviteTokens();
        }
        return new Response(
          JSON.stringify({ valid: false, error: "Invalid or expired token" }),
          {
            status: 404,
            headers: { "Content-Type": "application/json", ...CORS_HEADERS },
          },
        );
      }
      const dashboardUrl = `${url.protocol}//${url.host}`;
      return new Response(
        JSON.stringify({
          valid: true,
          dashboard_url: dashboardUrl,
          team_name: "shipwright",
          expires_at: entry.expires_at,
        }),
        {
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        },
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
loadSessions();
loadDeveloperRegistry();
loadInviteTokens();
const pushInterval = setInterval(periodicPush, WS_PUSH_INTERVAL_MS);

// Stale claim reaper — runs every 5 minutes
const staleClaimInterval = setInterval(
  () => {
    try {
      const twoHoursAgo = Date.now() - 2 * 60 * 60 * 1000;
      for (const [key, dev] of developerRegistry) {
        if (dev.last_heartbeat < twoHoursAgo && dev.last_heartbeat > 0) {
          // Check if this developer has claimed issues via labels
          try {
            const result = execSync(
              `gh issue list --label "claimed:${dev.machine_name}" --state open --json number -q '.[].number'`,
              {
                encoding: "utf-8",
                timeout: 15000,
                stdio: ["pipe", "pipe", "pipe"],
              },
            ).trim();
            if (result) {
              const issues = result.split("\n").filter(Boolean);
              for (const issueNum of issues) {
                try {
                  execSync(
                    `gh issue edit ${issueNum} --remove-label "claimed:${dev.machine_name}"`,
                    { timeout: 10000, stdio: ["pipe", "pipe", "pipe"] },
                  );
                } catch {
                  /* label may already be removed */
                }
              }
            }
          } catch {
            /* gh may not be available or no issues found */
          }
        }
      }
    } catch {
      /* reaper errors are non-fatal */
    }
  },
  5 * 60 * 1000,
);

// Invite token cleanup — runs every 15 minutes
const inviteCleanupInterval = setInterval(
  () => {
    try {
      const now = Date.now();
      let removed = 0;
      for (const [key, entry] of inviteTokens) {
        if (new Date(entry.expires_at).getTime() < now) {
          inviteTokens.delete(key);
          removed++;
        }
      }
      if (removed > 0) saveInviteTokens();
    } catch {
      /* cleanup errors are non-fatal */
    }
  },
  15 * 60 * 1000,
);

// Graceful shutdown
process.on("SIGINT", () => {
  clearInterval(pushInterval);
  clearInterval(staleClaimInterval);
  clearInterval(inviteCleanupInterval);
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
