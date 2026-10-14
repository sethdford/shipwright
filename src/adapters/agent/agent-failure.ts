import type { SDKAssistantMessageError, SDKResultMessage } from "@anthropic-ai/claude-agent-sdk";
import type { AgentFailure, AgentFailureKind, AgentUsage } from "../../shared/kernel/ports";

export interface Collected {
  readonly result?: SDKResultMessage;
  readonly assistantError?: SDKAssistantMessageError;
  readonly thrown?: unknown;
}

export const ZERO_USAGE: AgentUsage = {
  costUsd: 0,
  inputTokens: 0,
  outputTokens: 0,
  durationMs: 0,
};

// Text fallbacks: only for thrown errors with no result, and for the API error string the CLI
// puts in `result` of a success+is_error message. Typed SDK signals always win.
const TRANSIENT_TEXT =
  /API Error: (429|5\d\d)|overloaded|rate.?limit|fetch failed|ECONNREFUSED|ECONNRESET|EAI_AGAIN|ETIMEDOUT/i;
const AUTH_TEXT = /authentication_error|invalid api key|API Error: 401|oauth token/i;

const ASSISTANT_ERROR_KIND: Partial<Record<SDKAssistantMessageError, AgentFailureKind>> = {
  rate_limit: "transient",
  overloaded: "transient",
  server_error: "transient",
  authentication_failed: "auth",
  billing_error: "auth",
  oauth_org_not_allowed: "auth",
  account_on_hold: "auth",
  verification_required: "auth",
  cloud_credential_error: "auth",
  max_output_tokens: "truncated",
};

const AUTH_STARTUP = new Set([
  "gateway_signin_required",
  "gateway_access_denied",
  "org_verify_failed",
  "org_pin_api_key_conflict",
  "org_pin_mismatch",
  "org_config_refused",
]);
const TRANSIENT_STARTUP = new Set([
  "org_config_required_unavailable",
  "remote_settings_required_unavailable",
  "worktree_unverified",
]);

function classifyText(message: string): AgentFailureKind {
  if (AUTH_TEXT.test(message)) return "auth";
  if (TRANSIENT_TEXT.test(message)) return "transient";
  return "execution";
}

function messageOf(c: Collected): string {
  const r = c.result;
  if (r?.subtype === "success" && r.is_error && r.result) return r.result;
  if (r && r.subtype !== "success" && r.errors?.length) return r.errors.join("; ");
  if (c.thrown !== undefined)
    return c.thrown instanceof Error ? c.thrown.message : String(c.thrown);
  return r ? "agent run failed" : "stream ended without result";
}

function kindOf(c: Collected, message: string): AgentFailureKind {
  const typed = c.assistantError ? ASSISTANT_ERROR_KIND[c.assistantError] : undefined;
  if (typed) return typed;
  const r = c.result;
  if (r && r.subtype !== "success" && r.startup_failure_reason) {
    if (AUTH_STARTUP.has(r.startup_failure_reason)) return "auth";
    if (TRANSIENT_STARTUP.has(r.startup_failure_reason)) return "transient";
  }
  // errors[] on error results is not regex-classified: the SDK emits the typed signal for API errors.
  if (!r && c.thrown !== undefined) return classifyText(message);
  if (r?.subtype === "success" && r.is_error) return classifyText(message);
  return "execution";
}

export function failure(
  c: Collected,
  usage: AgentUsage,
  aborted: boolean,
  timedOut: boolean,
): AgentFailure {
  const sessionId = c.result?.session_id;
  const fail = (kind: AgentFailureKind, message: string): AgentFailure =>
    sessionId ? { kind, message, usage, sessionId } : { kind, message, usage };
  if (timedOut) return fail("timeout", "agent call timed out");
  if (aborted) return fail("aborted", "agent call aborted");
  if (c.result?.stop_reason === "refusal") return fail("refusal", "model refused");
  if (c.result?.stop_reason === "max_tokens") return fail("truncated", "output hit max tokens");
  switch (c.result?.subtype) {
    case "error_max_turns":
      return fail("max_turns", "reached max turns");
    case "error_max_budget_usd":
      return fail("budget", "reached budget cap");
    case "error_max_structured_output_retries":
      return fail("schema", "no valid structured output");
  }
  const message = messageOf(c);
  return fail(kindOf(c, message), message);
}
