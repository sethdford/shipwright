import { CORS_HEADERS } from "../middleware/constants.js";
import { loadQualitySummary, parseWindowDays, qualityPaths } from "../services/quality-sources.js";

/**
 * GET /api/quality?days=N — the Quality tab's read model: scorecard, compute router, merge
 * verifier, tournaments, acceptance tests, governance, trust boundary and cost. Read-only, like
 * every GET route; the role check (route-authz) applies only to mutating methods.
 */
export function handleQualityRoute(
  req: Request,
  url: URL,
  env: { home: string; stateDir?: string },
): Response | null {
  if (url.pathname !== "/api/quality" || req.method !== "GET") return null;
  const summary = loadQualitySummary(
    qualityPaths(env.home, env.stateDir),
    parseWindowDays(url.searchParams.get("days")),
  );
  return new Response(JSON.stringify(summary), {
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...CORS_HEADERS },
  });
}
