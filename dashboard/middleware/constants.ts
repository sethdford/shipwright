// Shared constants and configuration
// Never "*": Access-Control-Allow-Origin is set per request for allowlisted origins only
// (services/request-guard.ts withCors).
export const CORS_HEADERS = {
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-Shipwright-Token, Authorization",
};

export const WS_PUSH_INTERVAL_MS = 2000;
export const MAX_WS_CLIENTS = 50;
export const WS_CONNECTION_TIMEOUT_MS = 30 * 60 * 1000; // 30 minutes

export const SESSION_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours
export const ALLOWED_PERMISSIONS = ["admin", "write"];

// ANSI color codes
export const CYAN = "\x1b[38;2;0;212;255m";
export const GREEN = "\x1b[38;2;74;222;128m";
export const BOLD = "\x1b[1m";
export const DIM = "\x1b[2m";
export const ULINE = "\x1b[4m";
export const RESET = "\x1b[0m";
