import { join, extname } from "path";
import { readFileSync, existsSync, writeFileSync, mkdirSync, renameSync } from "fs";
import type { Session, AuthMode } from "../types/index.js";
import { SESSION_TTL_MS } from "./constants.js";

// Auth Config
const GITHUB_CLIENT_ID = process.env.GITHUB_CLIENT_ID || "";
const GITHUB_CLIENT_SECRET = process.env.GITHUB_CLIENT_SECRET || "";
const GITHUB_PAT = process.env.GITHUB_PAT || "";
const DASHBOARD_REPO = process.env.DASHBOARD_REPO || "";
const SESSION_SECRET = process.env.SESSION_SECRET || crypto.randomUUID();

const HOME = process.env.HOME || "";
const SESSIONS_FILE = join(HOME, ".shipwright", "sessions.json");

export const sessions = new Map<string, Session>();

export function createSession(data: Omit<Session, "expiresAt">): string {
  const sessionId = crypto.randomUUID();
  sessions.set(sessionId, {
    ...data,
    expiresAt: Date.now() + SESSION_TTL_MS,
  });
  saveSessions();
  return sessionId;
}

export function getSession(req: Request): Session | null {
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

export function getSessionFromCookie(cookie: string | null): Session | null {
  if (!cookie) return null;
  const match = cookie.match(/fleet_session=([^;]+)/);
  if (!match) return null;
  const session = sessions.get(match[1]);
  if (!session || Date.now() > session.expiresAt) return null;
  return session;
}

export function sessionCookie(sessionId: string): string {
  return `fleet_session=${sessionId}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`;
}

export function isLocalConnection(req: Request): boolean {
  const host = req.headers.get("host") || "";
  return (
    host.startsWith("localhost:") ||
    host.startsWith("127.0.0.1:") ||
    host.startsWith("[::1]:")
  );
}

export function clearSessionCookie(): string {
  return "fleet_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0";
}

export function loadSessions(): void {
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

export function saveSessions(): void {
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

export function getAuthMode(): AuthMode {
  if (GITHUB_CLIENT_ID && GITHUB_CLIENT_SECRET && DASHBOARD_REPO)
    return "oauth";
  if (GITHUB_PAT && DASHBOARD_REPO) return "pat";
  return "none";
}

export function isAuthEnabled(): boolean {
  return getAuthMode() !== "none";
}

export function isPublicRoute(pathname: string): boolean {
  return (
    pathname === "/login" ||
    pathname.startsWith("/auth/") ||
    pathname === "/api/health" ||
    pathname === "/api/ws-status" ||
    pathname === "/api/join" ||
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

export { SESSION_SECRET, GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, GITHUB_PAT, DASHBOARD_REPO };
