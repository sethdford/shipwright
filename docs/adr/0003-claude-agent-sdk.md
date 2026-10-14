# 0003. Claude Agent SDK behind one port

Status: accepted · Date: 2026-10-13

## Context
Bash called `claude -p` in dozens of places and parsed text. An empty reply silently meant
"reject", and model output reached shells. CI authenticates with `CLAUDE_CODE_OAUTH_TOKEN` only.

## Decision
All Claude access goes through the `AgentRunner` port in `src/shared/kernel/ports.ts`, implemented
once in `src/adapters/agent/` with `@anthropic-ai/claude-agent-sdk`, pinned to an exact version
(0.3.296) because its option names are load-bearing.

- `decide<T>`: one-shot, no tools, `permissionMode: "dontAsk"`, JSON-schema output validated with
  zod.
- `runTask`: agentic in a worktree, with a tool allowlist, `permissionMode: "dontAsk"`, and budget,
  turn and wall-clock caps.

Untrusted text (issues, PRs, comments) is passed only as delimited data in the user turn. The child
environment is built from an allowlist, so `GH_TOKEN` and `GITHUB_TOKEN` never reach the agent.
Rule F6 confines the SDK import to `adapters/agent/`.

## Consequences
- Typed failures (refusal, budget, max turns, schema, timeout) replace silent defaults.
- One credential works in CI.
- SDK upgrades are deliberate: bump the pin and rerun the adapter tests.
- Deferred: a direct Messages API adapter for cheap batch triage (it needs an API key). Credential
  scrubbing for tool subprocesses and the sandbox are recorded in ADR-0006 (Wave 1).
