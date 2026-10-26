import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";
import * as api from "./api";
import { store } from "./state";

// Mock global fetch
const mockFetch = vi.fn();
global.fetch = mockFetch;

function jsonResponse(data: unknown, status = 200) {
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(data),
  });
}

function errorResponse(status: number, body?: unknown) {
  return Promise.resolve({
    ok: false,
    status,
    json: () => Promise.resolve(body || { error: `HTTP ${status}` }),
  });
}

describe("API Client", () => {
  beforeEach(() => {
    mockFetch.mockReset();
    // Mutations are gated on a live connection and a loaded role (core/guard.ts).
    store.set("connected", true);
    store.set("currentUser", { username: "ada", role: "operator" });
  });

  describe("action gate", () => {
    it("refuses mutations while disconnected, without calling fetch", async () => {
      store.set("connected", false);
      await expect(api.sendIntervention(1, "pause")).rejects.toThrow(/Not connected/);
      expect(mockFetch).not.toHaveBeenCalled();
    });

    it("refuses mutations until the role has loaded, and for viewers", async () => {
      store.set("currentUser", null);
      await expect(api.emergencyBrake()).rejects.toThrow(/role/);
      store.set("currentUser", { username: "v", role: "viewer" });
      await expect(api.daemonControl("pause")).rejects.toThrow(/Viewers/);
      expect(mockFetch).not.toHaveBeenCalled();
    });

    it("never gates reads", async () => {
      store.set("connected", false);
      store.set("currentUser", null);
      mockFetch.mockReturnValue(jsonResponse({ alerts: [] }));
      await expect(api.fetchAlerts()).resolves.toEqual({ alerts: [] });
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("fetchMe", () => {
    it("calls GET /api/me", async () => {
      const userData = { username: "test", role: "admin" };
      mockFetch.mockReturnValueOnce(jsonResponse(userData));

      const result = await api.fetchMe();
      expect(result).toEqual(userData);
      expect(mockFetch).toHaveBeenCalledWith("/api/me", undefined);
    });
  });

  describe("fetchPipelineDetail", () => {
    it("calls GET /api/pipeline/:issue", async () => {
      const detail = { issue: 42, status: "building" };
      mockFetch.mockReturnValueOnce(jsonResponse(detail));

      const result = await api.fetchPipelineDetail(42);
      expect(result).toEqual(detail);
      expect(mockFetch).toHaveBeenCalledWith("/api/pipeline/42", undefined);
    });

    it("encodes special characters in issue", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchPipelineDetail("test/123");
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/test%2F123",
        undefined,
      );
    });
  });

  describe("fetchMetricsHistory", () => {
    it("defaults to 30 day period", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ history: [] }));
      await api.fetchMetricsHistory();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/metrics/history?period=30",
        undefined,
      );
    });

    it("respects custom period", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ history: [] }));
      await api.fetchMetricsHistory(7);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/metrics/history?period=7",
        undefined,
      );
    });
  });

  describe("fetchTimeline", () => {
    it("defaults to 24h range", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse([]));
      await api.fetchTimeline();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/timeline?range=24h",
        undefined,
      );
    });
  });

  describe("fetchActivity", () => {
    it("builds query string from params", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ events: [], hasMore: false }),
      );
      await api.fetchActivity({ limit: 50, offset: 10, type: "error" });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain("/api/activity?");
      expect(url).toContain("limit=50");
      expect(url).toContain("offset=10");
      expect(url).toContain("type=error");
    });

    it("excludes type=all from query string", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ events: [], hasMore: false }),
      );
      await api.fetchActivity({ type: "all" });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).not.toContain("type=");
    });
  });

  describe("machine operations", () => {
    it("fetchMachines calls GET /api/machines", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse([]));
      await api.fetchMachines();
      expect(mockFetch).toHaveBeenCalledWith("/api/machines", undefined);
    });

    it("addMachine calls POST /api/machines", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ name: "m1" }));
      await api.addMachine({ name: "m1", host: "localhost" });

      expect(mockFetch).toHaveBeenCalledWith("/api/machines", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "m1", host: "localhost" }),
      });
    });

    it("updateMachine calls PATCH /api/machines/:name", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ name: "m1" }));
      await api.updateMachine("m1", { status: "active" });

      expect(mockFetch).toHaveBeenCalledWith("/api/machines/m1", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ status: "active" }),
      });
    });

    it("removeMachine calls DELETE /api/machines/:name", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.removeMachine("m1");

      expect(mockFetch).toHaveBeenCalledWith("/api/machines/m1", {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
      });
    });
  });

  describe("fetchQueueDetailed", () => {
    it("transforms queue property to items", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ queue: [{ id: 1 }, { id: 2 }] }),
      );
      const result = await api.fetchQueueDetailed();
      expect(result).toEqual({ items: [{ id: 1 }, { id: 2 }] });
    });

    it("handles missing queue property gracefully", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      const result = await api.fetchQueueDetailed();
      expect(result).toEqual({ items: [] });
    });
  });

  describe("emergency brake", () => {
    it("calls POST /api/emergency-brake", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.emergencyBrake();

      expect(mockFetch).toHaveBeenCalledWith("/api/emergency-brake", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
      });
    });
  });

  describe("sendIntervention", () => {
    it("calls POST /api/intervention/:issue/:action with body", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.sendIntervention(42, "pause", { reason: "testing" });

      expect(mockFetch).toHaveBeenCalledWith("/api/intervention/42/pause", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ reason: "testing" }),
      });
    });
  });

  describe("insights endpoints", () => {
    it("fetchPatterns returns empty array on error", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(500));
      const result = await api.fetchPatterns();
      expect(result).toEqual({ patterns: [] });
    });

    it("fetchDecisions returns empty array on error", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(500));
      const result = await api.fetchDecisions();
      expect(result).toEqual({ decisions: [] });
    });

    it("fetchHeatmap returns null on error", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(500));
      const result = await api.fetchHeatmap();
      expect(result).toBeNull();
    });
  });

  describe("pipeline live changes", () => {
    it("fetchPipelineDiff calls correct endpoint", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({
          diff: "diff output",
          stats: { files_changed: 1, insertions: 10, deletions: 5 },
          worktree: "/path",
        }),
      );
      await api.fetchPipelineDiff(142);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/142/diff",
        undefined,
      );
    });

    it("fetchPipelineFiles calls correct endpoint", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({
          files: [{ path: "src/main.ts", status: "modified" }],
        }),
      );
      await api.fetchPipelineFiles(142);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/142/files",
        undefined,
      );
    });

    it("fetchPipelineReasoning calls correct endpoint", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ reasoning: [] }));
      await api.fetchPipelineReasoning(142);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/142/reasoning",
        undefined,
      );
    });

    it("fetchPipelineFailures calls correct endpoint", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ failures: [] }));
      await api.fetchPipelineFailures(142);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/142/failures",
        undefined,
      );
    });
  });

  describe("approval gates", () => {
    it("approveGate sends POST with stage", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.approveGate(42, "build");

      expect(mockFetch).toHaveBeenCalledWith("/api/approval-gates/42/approve", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ stage: "build" }),
      });
    });

    it("rejectGate sends POST with stage and reason", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.rejectGate(42, "build", "Failed QA");

      expect(mockFetch).toHaveBeenCalledWith("/api/approval-gates/42/reject", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ stage: "build", reason: "Failed QA" }),
      });
    });
  });

  describe("notifications", () => {
    it("addWebhook sends POST", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.addWebhook("https://slack.com/hook", "Slack", ["failure"]);

      expect(mockFetch).toHaveBeenCalledWith("/api/notifications/webhook", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          url: "https://slack.com/hook",
          label: "Slack",
          events: ["failure"],
        }),
      });
    });

    it("removeWebhook sends DELETE", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.removeWebhook("https://slack.com/hook");

      expect(mockFetch).toHaveBeenCalledWith("/api/notifications/webhook", {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url: "https://slack.com/hook" }),
      });
    });
  });

  describe("machine claim/release", () => {
    it("claimIssue sends POST with issue and machine", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ approved: true, claimed_by: "m1" }),
      );
      const result = await api.claimIssue(42, "m1");
      expect(result.approved).toBe(true);
    });

    it("releaseIssue sends POST", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.releaseIssue(42, "m1");

      expect(mockFetch).toHaveBeenCalledWith("/api/claim/release", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ issue: 42, machine: "m1" }),
      });
    });
  });

  describe("machine health check and join tokens", () => {
    it("machineHealthCheck calls POST", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ machine: {} }));
      await api.machineHealthCheck("node-1");
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/machines/node-1/health-check",
        expect.objectContaining({ method: "POST" }),
      );
    });

    it("fetchJoinTokens calls GET /api/join-token", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ tokens: [] }));
      await api.fetchJoinTokens();
      expect(mockFetch).toHaveBeenCalledWith("/api/join-token", undefined);
    });

    it("generateJoinToken calls POST /api/join-token", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ join_cmd: "sw join ..." }));
      await api.generateJoinToken({ label: "test", max_workers: 4 });
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/join-token",
        expect.objectContaining({ method: "POST" }),
      );
    });
  });

  describe("costs", () => {
    it("fetchCostBreakdown defaults to 7 day period", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchCostBreakdown();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/costs/breakdown?period=7",
        undefined,
      );
    });

    it("fetchCostTrend defaults to 30 day period", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ points: [] }));
      await api.fetchCostTrend();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/costs/trend?period=30",
        undefined,
      );
    });
  });

  describe("daemon", () => {
    it("fetchDaemonConfig calls GET /api/daemon/config", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchDaemonConfig();
      expect(mockFetch).toHaveBeenCalledWith("/api/daemon/config", undefined);
    });

    it("daemonControl calls POST /api/daemon/:action", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.daemonControl("pause");
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/daemon/pause",
        expect.objectContaining({ method: "POST" }),
      );
    });
  });

  describe("alerts and artifacts", () => {
    it("fetchAlerts calls GET /api/alerts", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ alerts: [] }));
      await api.fetchAlerts();
      expect(mockFetch).toHaveBeenCalledWith("/api/alerts", undefined);
    });

    it("fetchArtifact calls correct endpoint", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ content: "..." }));
      await api.fetchArtifact(42, "plan");
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/artifacts/42/plan",
        undefined,
      );
    });

    it("fetchGitHubStatus calls GET", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchGitHubStatus(42);
      expect(mockFetch).toHaveBeenCalledWith("/api/github/42", undefined);
    });

    it("fetchLogs calls GET", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ content: "log" }));
      await api.fetchLogs(42);
      expect(mockFetch).toHaveBeenCalledWith("/api/logs/42", undefined);
    });
  });

  describe("metrics detail", () => {
    it("fetchStagePerformance defaults to 7 days", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ stages: [] }));
      await api.fetchStagePerformance();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/metrics/stage-performance?period=7",
        undefined,
      );
    });

    it("fetchBottlenecks calls GET", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ bottlenecks: [] }));
      await api.fetchBottlenecks();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/metrics/bottlenecks",
        undefined,
      );
    });

    it("fetchThroughputTrend defaults to 30 days", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ points: [] }));
      await api.fetchThroughputTrend();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/metrics/throughput-trend?period=30",
        undefined,
      );
    });

    it("fetchCapacity calls GET", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ rate: 2, queue_clear_hours: 1 }),
      );
      await api.fetchCapacity();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/metrics/capacity",
        undefined,
      );
    });

    it("fetchDoraTrend defaults to 30 days", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchDoraTrend();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/metrics/dora-trend?period=30",
        undefined,
      );
    });
  });

  describe("team endpoints", () => {
    it("fetchTeam calls GET /api/team", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchTeam();
      expect(mockFetch).toHaveBeenCalledWith("/api/team", undefined);
    });

    it("fetchTeamActivity returns events array", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ events: [{ id: 1 }] }));
      const result = await api.fetchTeamActivity();
      expect(result).toEqual([{ id: 1 }]);
    });

    it("fetchTeamActivity returns empty array on error", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(500));
      const result = await api.fetchTeamActivity();
      expect(result).toEqual([]);
    });

    it("createTeamInvite calls POST /api/team/invite", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ token: "abc", join_url: "...", command: "...", expires_at: "..." }),
      );
      await api.createTeamInvite({ expires_hours: 24 });
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/team/invite",
        expect.objectContaining({ method: "POST" }),
      );
    });
  });

  describe("pipeline test results and learnings", () => {
    it("fetchPipelineTestResults calls GET", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchPipelineTestResults(42);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/42/test-results",
        undefined,
      );
    });

    it("fetchGlobalLearnings calls GET", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ learnings: [] }));
      await api.fetchGlobalLearnings();
      expect(mockFetch).toHaveBeenCalledWith("/api/memory/global", undefined);
    });

    it("fetchPatrol returns findings on success", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ findings: [{ id: 1 }] }));
      const result = await api.fetchPatrol();
      expect(result).toEqual({ findings: [{ id: 1 }] });
    });
  });

  describe("integration and DB endpoints", () => {
    it("fetchLinearStatus calls GET", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchLinearStatus();
      expect(mockFetch).toHaveBeenCalledWith("/api/linear/status", undefined);
    });

    it("fetchDbEvents with defaults", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ events: [], source: "db" }));
      await api.fetchDbEvents();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/db/events?since=0&limit=200",
        undefined,
      );
    });

    it("fetchDbJobs without status filter", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ jobs: [], source: "db" }));
      await api.fetchDbJobs();
      expect(mockFetch).toHaveBeenCalledWith("/api/db/jobs", undefined);
    });

    it("fetchDbJobs with status filter", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ jobs: [], source: "db" }));
      await api.fetchDbJobs("active");
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/db/jobs?status=active",
        undefined,
      );
    });

    it("fetchDbCostsToday calls GET", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchDbCostsToday();
      expect(mockFetch).toHaveBeenCalledWith("/api/db/costs/today", undefined);
    });

    it("fetchDbHeartbeats calls GET", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ heartbeats: [], source: "db" }),
      );
      await api.fetchDbHeartbeats();
      expect(mockFetch).toHaveBeenCalledWith("/api/db/heartbeats", undefined);
    });

    it("fetchDbHealth calls GET", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchDbHealth();
      expect(mockFetch).toHaveBeenCalledWith("/api/db/health", undefined);
    });
  });

  describe("audit, quality gates, approvals, notifications", () => {
    it("fetchAuditLog calls GET", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ entries: [] }));
      await api.fetchAuditLog();
      expect(mockFetch).toHaveBeenCalledWith("/api/audit-log", undefined);
    });

    it("fetchQualityGates calls GET", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ enabled: true, rules: [] }));
      await api.fetchQualityGates();
      expect(mockFetch).toHaveBeenCalledWith("/api/quality-gates", undefined);
    });

    it("fetchPipelineQuality calls GET", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ quality: {}, gates: {}, results: [] }),
      );
      await api.fetchPipelineQuality(42);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/42/quality",
        undefined,
      );
    });

    it("fetchApprovalGates calls GET", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ enabled: true, stages: [], pending: [] }),
      );
      await api.fetchApprovalGates();
      expect(mockFetch).toHaveBeenCalledWith("/api/approval-gates", undefined);
    });

    it("updateApprovalGates calls POST", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.updateApprovalGates({ enabled: true, stages: ["review"] });
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/approval-gates",
        expect.objectContaining({ method: "POST" }),
      );
    });

    it("fetchNotificationConfig calls GET", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ enabled: true, webhooks: [] }),
      );
      await api.fetchNotificationConfig();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/notifications/config",
        undefined,
      );
    });

    it("testNotification calls POST", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.testNotification();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/notifications/test",
        expect.objectContaining({ method: "POST" }),
      );
    });
  });

  describe("error handling", () => {
    it("throws on non-ok response", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(404, { error: "Not found" }));

      await expect(api.fetchMe()).rejects.toThrow("Not found");
    });

    it("falls back to HTTP status on unparseable error", async () => {
      mockFetch.mockReturnValueOnce(
        Promise.resolve({
          ok: false,
          status: 500,
          json: () => Promise.reject(new Error("parse error")),
        }),
      );

      await expect(api.fetchMe()).rejects.toThrow("HTTP 500");
    });

    it("fetchPredictions returns empty object on error", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(500));
      const result = await api.fetchPredictions(42);
      expect(result).toEqual({});
    });
  });
});
