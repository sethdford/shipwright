# Shipwright

Shipwright orchestrates autonomous Claude Code agent teams with delivery pipelines, daemon-driven issue processing, fleet operations across multiple repos, persistent memory, DORA metrics, cost intelligence, and repo preparation. CLI aliases `shipwright` and `sw` work identically.

## Commands

100+ commands organized by workflow. CLI aliases `shipwright` and `sw` work identically.

### Core Workflow

| Command                                            | Purpose                                           |
| -------------------------------------------------- | ------------------------------------------------- |
| `shipwright pipeline start --issue <N>`            | Full delivery pipeline for an issue               |
| `shipwright pipeline start --issue <N> --worktree` | Pipeline in isolated git worktree (parallel-safe) |
| `shipwright pipeline start --goal "..."`           | Pipeline from a goal description                  |
| `shipwright pipeline start --detach`               | Start pipeline in background (tmux detached)      |
| `shipwright pipeline start --foreground`           | Force foreground even with `--worktree`           |
| `shipwright pipeline resume`                       | Resume from last stage                            |
| `shipwright pipeline attach [issue]`               | Attach to running pipeline's tmux window          |
| `shipwright pipeline tail [issue]`                 | Stream live pipeline output (like `tail -f`)      |
| `shipwright loop "<goal>" --test-cmd "..."`        | Continuous autonomous agent loop                  |
| `shipwright daemon start`                          | Watch repo for labeled issues, auto-process       |
| `shipwright daemon start --detach`                 | Start daemon in background tmux session           |
| `shipwright daemon metrics`                        | DORA/DX metrics dashboard                         |
| `shipwright autonomous <cmd>`                      | AI-building-AI master controller                  |

### Agent Management

| Command                                   | Purpose                                    |
| ----------------------------------------- | ------------------------------------------ |
| `shipwright swarm <cmd>`                  | Dynamic agent swarm orchestration          |
| `shipwright recruit <cmd>`                | Agent recruitment & talent management      |
| `shipwright standup`                      | Automated daily standups for AI teams      |
| `shipwright guild <cmd>`                  | Knowledge guilds & cross-team learning     |
| `shipwright oversight <cmd>`              | Quality oversight board                    |
| `shipwright pm <cmd>`                     | Autonomous PM agent for team orchestration |
| `shipwright team-stages <cmd>`            | Multi-agent execution with roles           |
| `shipwright session <name> -t <template>` | Create team session with agent panes       |
| `shipwright scale <cmd>`                  | Dynamic agent team scaling                 |

### Quality & Review

| Command                     | Purpose                                  |
| --------------------------- | ---------------------------------------- |
| `shipwright code-review`    | Clean code & architecture analysis       |
| `shipwright security-audit` | Comprehensive security auditing          |
| `shipwright testgen`        | Autonomous test generation & coverage    |
| `shipwright hygiene`        | Repository organization & cleanup        |
| `shipwright adversarial`    | Red-team code review & edge case finding |
| `shipwright simulation`     | Multi-persona developer simulation       |
| `shipwright architecture`   | Living architecture model & enforcement  |
| `shipwright quality <cmd>`  | Intelligent completion audits            |

### Observability & Monitoring

| Command                           | Purpose                                    |
| --------------------------------- | ------------------------------------------ |
| `shipwright vitals`               | Pipeline vitals — real-time health scoring |
| `shipwright dora`                 | DORA metrics dashboard with intelligence   |
| `shipwright retro`                | Sprint retrospective engine                |
| `shipwright stream`               | Live terminal output streaming from panes  |
| `shipwright activity`             | Live agent activity stream                 |
| `shipwright replay`               | Pipeline run replay & timeline viewing     |
| `shipwright status`               | Team dashboard                             |
| `shipwright logs <team> --follow` | Tail agent logs                            |
| `shipwright ps`                   | Show running agent processes               |
| `shipwright heartbeat list`       | Show agent heartbeat status                |

### Release & Deployment

| Command                           | Purpose                                                   |
| --------------------------------- | --------------------------------------------------------- |
| `shipwright release`              | Release train automation                                  |
| `shipwright release build`        | Build release tarballs (darwin/linux) for GitHub Releases |
| `shipwright release-manager`      | Autonomous release pipeline                               |
| `shipwright changelog`            | Automated release notes & migration guides                |
| `shipwright version bump <x.y.z>` | Bump version everywhere (scripts, README, package.json)   |
| `shipwright version check`        | Verify version consistency (CI / before release)          |
| `shipwright deploys list`         | List GitHub deployments by environment                    |
| `shipwright durable <cmd>`        | Durable workflow engine for long-running ops              |

### Intelligence & Optimization

| Command                   | Purpose                                        |
| ------------------------- | ---------------------------------------------- |
| `shipwright intelligence` | Run intelligence engine analysis               |
| `shipwright predict`      | Predictive risk assessment & anomaly detection |
| `shipwright strategic`    | Strategic intelligence agent                   |
| `shipwright optimize`     | Self-optimization based on DORA metrics        |
| `shipwright model-router` | Intelligent model routing & cost optimization  |
| `shipwright adaptive`     | Data-driven pipeline tuning                    |

### Issue & Ticket Management

| Command                            | Purpose                                     |
| ---------------------------------- | ------------------------------------------- |
| `shipwright triage`                | Intelligent issue labeling & prioritization |
| `shipwright decompose --issue <N>` | AI-split complex features into subtasks     |
| `shipwright tracker <cmd>`         | Provider router for tracker integration     |
| `shipwright jira <cmd>`            | Jira ↔ GitHub bidirectional sync            |
| `shipwright linear <cmd>`          | Linear ↔ GitHub bidirectional sync          |
| `shipwright pr`                    | Autonomous PR management                    |

### Infrastructure & Operations

| Command                                   | Purpose                                         |
| ----------------------------------------- | ----------------------------------------------- |
| `shipwright fleet start`                  | Multi-repo daemon orchestration                 |
| `shipwright fleet discover --org <org>`   | Auto-discovery of repos in GitHub org           |
| `shipwright fleet-viz`                    | Multi-repo fleet visualization                  |
| `shipwright fix "<goal>" --repos <paths>` | Bulk fix across multiple repos in parallel      |
| `shipwright remote list`                  | Show registered remote machines                 |
| `shipwright remote add <name> --host <h>` | Register a remote worker machine                |
| `shipwright remote status`                | Health check all remote machines                |
| `shipwright connect start`                | Sync local state to team dashboard              |
| `shipwright connect join --token <t>`     | Join a team using an invite token               |
| `shipwright connect status`               | Show connection status                          |
| `shipwright dashboard`                    | Real-time web dashboard                         |
| `shipwright dashboard start`              | Start dashboard in background                   |
| `shipwright public-dashboard`             | Public real-time pipeline progress              |
| `shipwright mission-control`              | Terminal-based pipeline mission control         |
| `shipwright launchd install`              | Auto-start daemon + dashboard + connect on boot |

### GitHub & CI/CD

| Command                       | Purpose                                         |
| ----------------------------- | ----------------------------------------------- |
| `shipwright ci <cmd>`         | GitHub Actions CI/CD orchestration              |
| `shipwright github-app <cmd>` | GitHub App management & webhook receiver        |
| `shipwright webhook <cmd>`    | GitHub webhook receiver for instant processing  |
| `shipwright checks list`      | List GitHub Check runs for a commit             |
| `shipwright github context`   | Show repo GitHub context                        |
| `shipwright github security`  | CodeQL + Dependabot security alerts             |
| `shipwright trace`            | E2E traceability (Issue → Commit → PR → Deploy) |
| `shipwright instrument`       | Pipeline instrumentation & feedback loops       |

### Data, Learning & Memory

| Command                               | Purpose                                    |
| ------------------------------------- | ------------------------------------------ |
| `shipwright memory show`              | View captured failure patterns & learnings |
| `shipwright cost show`                | Token usage and spending dashboard         |
| `shipwright cost budget set <amount>` | Set daily budget limit                     |
| `shipwright db <cmd>`                 | SQLite persistence layer management        |
| `shipwright eventbus subscribe`       | Subscribe to real-time events by type      |
| `shipwright eventbus reaper`          | Clean up expired/consumed events           |
| `shipwright eventbus watch`           | Live event stream viewer                   |
| `shipwright eventbus replay`          | Replay events from a time range            |
| `shipwright eventbus status`          | Show bus health and pending event counts   |
| `shipwright eventbus clean`           | Purge old events beyond retention window   |
| `shipwright discovery <cmd>`          | Cross-pipeline real-time learning          |
| `shipwright feedback <cmd>`           | Production feedback loop                   |
| `shipwright regression`               | Regression detection pipeline              |
| `shipwright otel`                     | OpenTelemetry observability                |

### Setup, Maintenance & Configuration

| Command                               | Purpose                                    |
| ------------------------------------- | ------------------------------------------ |
| `shipwright init`                     | One-command tmux setup                     |
| `shipwright setup`                    | Guided setup — prerequisites, init, doctor |
| `shipwright prep`                     | Analyze repo and generate .claude/ configs |
| `shipwright doctor`                   | Validate setup and diagnose issues         |
| `shipwright upgrade --apply`          | Pull latest and apply updates              |
| `shipwright cleanup --force`          | Kill orphaned sessions                     |
| `shipwright reaper --watch`           | Automatic pane cleanup when agents exit    |
| `shipwright worktree create <branch>` | Git worktree for agent isolation           |
| `shipwright templates list`           | Browse team templates                      |
| `shipwright docs <cmd>`               | Documentation keeper                       |
| `shipwright docs-agent`               | Auto-sync README, wiki, API docs           |
| `shipwright tmux <cmd>`               | tmux health & plugin management            |
| `shipwright tmux-pipeline`            | Spawn and manage pipelines in tmux         |
| `shipwright checkpoint list`          | Show saved pipeline checkpoints            |
| `shipwright auth <cmd>`               | GitHub OAuth authentication                |
| `shipwright incident <cmd>`           | Autonomous incident detection & response   |

### Advanced & Experimental

| Command                       | Purpose                                |
| ----------------------------- | -------------------------------------- |
| `shipwright e2e-orchestrator` | Test suite registry & execution        |
| `shipwright ux`               | Premium UX enhancement layer           |
| `shipwright widgets`          | Embeddable status widgets              |
| `shipwright context gather`   | Assemble rich context for stages       |
| `shipwright deps <cmd>`       | Automated dependency update management |

## Pipeline Stages

14 stages, each can be enabled/disabled and gated (auto-proceed or pause for approval):

```
intake → plan → design → spec_generation → build → test → review → spec_verification → compound_quality → pr → merge → deploy → validate → monitor
```

- **spec_generation**: After design, generates `spec.json` with acceptance criteria, edge cases, security requirements. Disabled via `SPEC_DRIVEN_ENABLED=false`.
- **spec_verification**: After review, verifies implementation compliance against spec criteria. Emits compliance score and metrics.

The build stage delegates to `shipwright loop` for autonomous multi-iteration development. Self-healing: when tests fail, the pipeline re-enters the build loop with error context.

### Build Loop Capabilities

- **Session restart** (`--max-restarts N`): When the loop exhausts iterations without completing, it restarts with a fresh Claude session that reads progress from `progress.md`. Git state = resume point. Default 0 (off) for manual, 3 for daemon.
- **Progress persistence**: `progress.md` written after each iteration with goal, iteration count, test status, recent commits, changed files. Fresh sessions orient from this file.
- **Structured error feedback**: `error-summary.json` written after test failures with machine-readable error lines. Injected into the next iteration prompt as structured context.
- **Fast test mode** (`--fast-test-cmd "cmd"`): Alternates between a fast subset test and the full suite. Full test runs on iteration 1, every N iterations (`--fast-test-interval`, default 5), and the final iteration.
- **Agent roles** (`--roles "builder,reviewer,tester"`): In multi-agent mode, assigns specialization per agent. Built-in roles: `builder`, `reviewer`, `tester`, `optimizer`, `docs`, `security`.
- **Context exhaustion detection**: When the daemon detects a build loop failed due to iteration exhaustion (not a code error), it tags the failure as `context_exhaustion` and boosts `--max-restarts` on retry.

## Pipeline Templates

| Template     | Stages                                     | Gates                             | Use Case                 |
| ------------ | ------------------------------------------ | --------------------------------- | ------------------------ |
| `fast`       | intake → build → test → PR                 | all auto                          | Quick fixes              |
| `standard`   | intake → plan → build → test → review → PR | approve: plan, review, pr         | Normal feature work      |
| `full`       | all stages                                 | approve: plan, review, pr, deploy | Production deployment    |
| `hotfix`     | intake → build → test → PR                 | all auto                          | Urgent production fixes  |
| `autonomous` | all stages                                 | all auto                          | Daemon-driven delivery   |
| `enterprise` | all stages                                 | all approve, auto-rollback        | Maximum safety           |
| `cost-aware` | all stages                                 | all auto, budget checks           | Budget-limited delivery  |
| `deployed`   | all + deploy + validate + monitor          | approve: deploy                   | Full deploy + monitoring |

## CLI Flags

All `claude` CLI invocations in the pipeline support these flags:

| Flag                   | Default          | Purpose                                                                       |
| ---------------------- | ---------------- | ----------------------------------------------------------------------------- |
| `--effort`             | auto (per stage) | Reasoning depth — now config-driven via `effort_levels` in daemon-config.json |
| `--fallback-model`     | `sonnet`         | Auto-fallback on rate limits — prevents pipeline failures                     |
| `--json-schema <json>` | —                | Structured output matching a schema (inline JSON, not file path)              |

### Effort Level Routing

Per-stage effort levels are config-driven via `daemon-config.json` `effort_levels` section. CLI `--effort` overrides config.

Effort is spent **asymmetrically**. Coding and agentic work is where it pays
off most, and refinement/review dominates agentic token cost — so `build`,
`review`, and `compound_quality` get the deep setting, while mechanical stages
stay cheap (lower effort there means fewer, more consolidated tool calls and
less preamble, which is what you want from intake/pr/merge). One `xhigh` review
pass is preferred over adding more review rounds.

| Stage                            | Default Effort | Rationale                                  |
| -------------------------------- | -------------- | ------------------------------------------ |
| intake, pr, merge                | low            | Mechanical/formatting tasks                |
| test, deploy, validate, monitor  | medium         | Standard development work                  |
| plan, design                     | high           | Complex reasoning, not code authoring      |
| spec_generation, spec_verification | high         | Specification analysis                     |
| build                            | xhigh          | Agentic coding — the stage that writes code |
| review, compound_quality         | xhigh          | One deep pass beats several cheaper rounds |

`max` is deliberately not a default anywhere: it shows diminishing returns and
can overthink. Reach for it per-run via `EFFORT_LEVEL_OVERRIDE` when
correctness matters more than cost. The ladder is pinned by tests in
`scripts/sw-lib-compat-test.sh`, which also assert every stage maps to a level
the `claude` CLI actually accepts.

Override globally via CLI: `--effort high` or via `daemon-config.json`:

```json
{ "effort_levels": { "intake": "low", "build": "high", "review": "high" } }
```

Environment variables: `SW_EFFORT_LEVEL`, `SW_FALLBACK_MODEL`.

### Prompt-Cache Stability and Session Continuity

Two loop-level controls that affect cost rather than behavior. Both target the
same thing: the build loop used to start a **cold Claude session every
iteration**, recomposing the prompt and re-paying cache writes.

| Control | Default | Effect |
| ------- | ------- | ------ |
| `LOOP_STABLE_PROMPT_PREFIX` | `true` | Passes `--exclude-dynamic-system-prompt-sections`, moving per-machine sections (cwd, env, memory paths, **git status**) out of the system prompt. Prompt caching is a prefix match, and git status changes constantly mid-loop — leaving it in the prefix invalidated everything after it on every iteration. Set `false` to restore the old behavior. |
| `--session-continuity` / `LOOP_SESSION_CONTINUITY=1` / `loop.session_continuity` | **off** | Reuses one `--session-id` across iterations so they continue a single conversation instead of cold-starting. |

Session continuity is **opt-in on purpose**. It changes conversation semantics —
the model carries prior turns rather than being re-briefed from `progress.md` —
so roll it out measured: run a pipeline with and without it and compare
`shipwright cost show`. A deliberate session restart (context-exhaustion
recovery) always allocates a **new** session id, because that path exists
precisely to drop stale context and re-orient from `progress.md`.

Note `shipwright loop --resume` is unrelated: that re-reads
`.claude/loop-state.md`, it does not continue a Claude session.

## Intelligent Defaults

Pipeline behavior is config-driven via `daemon-config.json`. Three helper functions in `scripts/lib/compat.sh` provide intelligent configuration chaining (env var → daemon-config.json → user config → hardcoded default):

| Function          | Purpose                                                                                        |
| ----------------- | ---------------------------------------------------------------------------------------------- |
| `_smart_model()`  | Returns model for a purpose. Chain: `SW_MODEL_<PURPOSE>` → `model_routing.<purpose>` → default |
| `_smart_int()`    | Reads integer config with env override and default fallback (e.g., circuit breaker threshold)  |
| `_smart_effort()` | Reads effort level per pipeline stage from config with intelligent defaults                    |

### Model Routing

Route different models to different tasks based on cost/capability needs:

```json
{
  "model_routing": {
    "default": "opus",
    "classification": "haiku",
    "detection": "haiku",
    "validation": "haiku",
    "commit_quality": "haiku",
    "high_risk": "opus"
  }
}
```

Purpose keys: `default` (fallback), `classification` (issue triage), `detection` (anomaly/stall), `validation` (quality checks), `commit_quality` (commit message review), `high_risk` (security-sensitive stages).

### Loop Configuration

Tune the build loop's resilience and restart behavior:

```json
{
  "loop": {
    "circuit_breaker_threshold": 4,
    "min_progress_lines": 3,
    "extension_size": 5,
    "max_extensions": 3,
    "context_restart_limit": 3,
    "hard_restart_cap": 5,
    "max_restarts": 3
  }
}
```

| Key                         | Default | Purpose                                           |
| --------------------------- | ------- | ------------------------------------------------- |
| `circuit_breaker_threshold` | `4`     | Consecutive failures before circuit breaker trips |
| `min_progress_lines`        | `3`     | Minimum changed lines to count as "progress"      |
| `extension_size`            | `5`     | Extra iterations granted per extension            |
| `max_extensions`            | `3`     | Maximum number of iteration extensions            |
| `context_restart_limit`     | `3`     | Max restarts due to context exhaustion            |
| `hard_restart_cap`          | `5`     | Absolute maximum restarts regardless of cause     |
| `max_restarts`              | `3`     | Default restart limit for daemon-driven loops     |

`hard_restart_cap` is enforced on the daemon retry path too: the context-exhaustion
boost to `--max-restarts` is clamped to it rather than to a hardcoded ceiling.

### Retry Escalation on Repeated Failure Signatures

Retry escalation used to be keyed on the retry *count* alone — retry 1 raised the
model, retry 2 switched to the `full` template — regardless of whether the pipeline
hit a new bug each time or ran into the identical one twice. The daemon now also
fingerprints *what* failed.

After each retryable failure, `normalize_failure_signature()` builds a
`<class>:<8 hex>` fingerprint from the log tail. Normalization strips everything
that varies between two runs of the same defect: ANSI colour, timestamps, absolute
directories (the basename is kept — the file is part of the identity), and all
digits (line numbers, PIDs, durations). Two runs of the same defect therefore
produce the same signature; a different defect produces a different one.

The signature is persisted per issue under `.failure_signatures[<issue>]` in the
daemon state file (`{signature, count, last_seen, history}`, history capped at 5),
so the streak survives a daemon restart. It is cleared when the issue succeeds.

When the same signature is seen `repeat_threshold` times in a row, the retry spawns
with the `model_routing.high_risk` model and effort one rung up the
`low→medium→high→xhigh→max` ladder. The effort base is the `build` stage's own level
when `effort_level` is unset, since build is the stage that produced the failure.
Escalating at the top of both ladders is a logged no-op, never an error.

```json
{
  "escalation": {
    "on_repeat_signature": 1,
    "repeat_threshold": 2
  }
}
```

| Key                   | Default | Purpose                                                        |
| --------------------- | ------- | -------------------------------------------------------------- |
| `on_repeat_signature` | `1`     | Enable signature tracking and escalation (`0` disables)        |
| `repeat_threshold`    | `2`     | Consecutive identical signatures required before escalating    |

Env overrides: `SW_ESCALATION_ON_REPEAT_SIGNATURE`, `SW_ESCALATION_REPEAT_THRESHOLD`.
Setting `RETRY_ESCALATION=false` disables the retry path entirely, signatures included.

Both decisions are observable in `events.jsonl`:

| Event                      | Fields                                                                                     |
| -------------------------- | ------------------------------------------------------------------------------------------ |
| `daemon.failure_signature` | `issue`, `signature`, `consecutive`, `retry` — emitted on every retry                      |
| `daemon.escalation`        | `issue`, `result=escalated`, `signature`, `consecutive`, `from_model`/`to_model`, `from_effort`/`to_effort` |
| `daemon.escalation`        | `issue`, `result=at_ceiling`, `signature`, `consecutive`, `model`, `effort`                |

## Constitutional AI

Code quality principles are defined in `config/code-constitution.json`. The constitution provides machine-checkable rules across five categories:

| Category         | IDs       | Examples                                                             |
| ---------------- | --------- | -------------------------------------------------------------------- |
| `security`       | SEC-001–5 | No hardcoded secrets, input validation, no eval with dynamic content |
| `error_handling` | ERR-001–4 | No empty catch blocks, descriptive errors, check return values       |
| `quality`        | QUA-001–5 | Functions under 100 lines, no magic numbers, no TODO in prod         |
| `testing`        | TST-001–4 | New functions need tests, test error/edge cases                      |
| `performance`    | PRF-001–3 | All queries need LIMIT, no unbounded loops, no sync I/O in hot paths |

Each rule has `id`, `rule`, `severity` (critical/high/medium/low), and optional `check` (grep command for automated detection). Used by the adversarial review stage and quality oversight agent for self-critique.

## Autonomous Agents in v2.0.0

**Wave 1 (Organizational Agents):**

| Agent              | Command   | Purpose                                               |
| ------------------ | --------- | ----------------------------------------------------- |
| Swarm Manager      | `swarm`   | Dynamic agent team orchestration, role specialization |
| Autonomous PM      | `pm`      | Team leadership, task scheduling, roadmap execution   |
| Knowledge Guild    | `guild`   | Cross-team learning, pattern capture, mentorship      |
| Recruitment System | `recruit` | Talent acquisition, team composition optimization     |
| Standup Automaton  | `standup` | Daily standups, progress tracking, blocker detection  |

**Wave 2 (Operational Backbone):**

| Agent                  | Command                   | Purpose                                              |
| ---------------------- | ------------------------- | ---------------------------------------------------- |
| Quality Oversight      | `oversight`               | Intelligent audits, zero-defect gates, completeness  |
| Strategic Agent        | `strategic`               | Long-term planning, goal decomposition, roadmap      |
| Code Reviewer          | `code-review`             | Architecture analysis, clean code, best practices    |
| Security Auditor       | `security-audit`          | Vulnerability detection, threat modeling, compliance |
| Test Generator         | `testgen`                 | Coverage analysis, scenario discovery, regression    |
| Incident Commander     | `incident`                | Autonomous triage, root cause, resolution            |
| Dependency Manager     | `deps`                    | Semantic versioning, updates, compatibility          |
| Release Manager        | `release-manager`         | Release planning, changelog, deployment              |
| Adaptive Tuner         | `adaptive`                | DORA metrics, self-optimization, performance         |
| Strategic Intelligence | (integrated in `predict`) | Predictive analysis, trend detection                 |

Each agent spawns specialized Claude Code sessions with domain-specific instructions. Agents coordinate via the task list and persistent memory.

## Local Mode

Run Shipwright entirely offline (no GitHub) for development and testing:

```bash
# Full pipeline without GitHub
shipwright pipeline start --goal "build auth module" --local

# Daemon mode locally
shipwright daemon start --no-github

# What works offline
- All 14 pipeline stages execute
- Intelligence layer operates
- Cost tracking (estimated)
- Memory system (local only)
- Agent teams
- Test execution
- Output to ~/.shipwright/local-artifacts/

# What requires --skip or degrades gracefully
- GitHub PR creation — skipped, saved to .claude/pr-draft.md
- Deployment tracking — skipped
- GitHub checks — skipped
- Contributor analysis — uses local git history only
- Security alerts — local scanning only
- CODEOWNERS — read from repo if present
```

Enable via config:

```json
{
  "local_mode": true,
  "skip_github": true,
  "offline_enabled": true
}
```

Or environment variables:

```bash
export SHIPWRIGHT_LOCAL=1
export NO_GITHUB=1
```

## Multi-Repo Operations

### Fleet Mode

Run daemon across multiple repositories with shared worker pool:

```bash
# Initialize fleet
shipwright fleet start

# Auto-discover repos in GitHub org
shipwright fleet discover --org myorg --language go,python

# Visualize fleet state
shipwright fleet-viz

# View fleet dashboard
shipwright dashboard --fleet

# Config at .claude/fleet-config.json
{
  "worker_pool": {
    "enabled": true,
    "total_workers": 12,
    "rebalance_interval_seconds": 120
  },
  "repos": [
    {
      "path": "/path/to/repo1",
      "priority": 1,
      "auto_sync": true,
      "labels": ["shipwright"]
    }
  ]
}
```

Worker pool scales across repos proportionally to queue depth and issue complexity.

### Bulk Fix Across Repos

Apply the same fix to multiple repositories in parallel:

```bash
# Single fix across many repos
shipwright fix "upgrade Go to 1.21" --repos \
  ~/projects/api,~/projects/cli,~/projects/sdk

# With custom test command per repo type
shipwright fix "add license header" \
  --repos ~/a,~/b,~/c \
  --test-cmd "npm test"

# With worktree isolation (true parallelism)
shipwright fix "refactor logging" \
  --repos ~/a,~/b,~/c \
  --worktree
```

Output:

```
Fix Results Across 3 Repos
  ~/projects/api     ✓ MERGED   (1 PR)
  ~/projects/cli     ✓ MERGED   (1 PR)
  ~/projects/sdk     ✓ MERGED   (1 PR)

Total: 3 PRs merged, $0.47 cost
```

### Per-Repo Pipeline Override

Control pipeline behavior per repository:

```bash
# Via environment
export SHIPWRIGHT_PIPELINE_TEMPLATE=fast     # global
export REPO_a_TEMPLATE=full                  # repo-specific

# Via fleet-config.json
{
  "repos": [
    {
      "path": "/path/to/repo",
      "pipeline_template": "full",
      "max_parallel_builds": 1,
      "auto_merge": false,
      "labels": ["shipwright", "gated"]
    }
  ]
}
```

### Distributed Execution

Execute pipeline steps on remote machines:

```bash
# Register remote worker
shipwright remote add builder-1 --host 192.168.1.50

# View health
shipwright remote status

# Configure in daemon-config.json
{
  "remote": {
    "enabled": true,
    "machines": ["builder-1", "builder-2"],
    "load_balance": true
  }
}
```

The daemon routes builds to remote workers, syncing state atomically.

## Team Patterns

- Assign each agent **different files** to avoid merge conflicts
- Use `--worktree` for file isolation between agents running concurrently
- Keep tasks self-contained — 5-6 focused tasks per agent
- Use the task list for coordination, not direct messaging
- 25 team templates cover the full SDLC: `shipwright templates list`
- Agents from Wave 1 coordinate Wave 2 specialists via PM agent

## tmux Integration

Shipwright includes a production tmux configuration optimized for Claude Code TUI compatibility, agent team workflows, and multi-pane management.

### Key Bindings

| Binding           | Action                                |
| ----------------- | ------------------------------------- |
| `prefix + T`      | Launch Shipwright team session        |
| `prefix + Ctrl-t` | Team dashboard in floating popup      |
| `prefix + G`      | Toggle zoom on current pane           |
| `prefix + g`      | Display pane numbers (type to select) |
| `prefix + F`      | Floating popup terminal               |
| `prefix + C-f`    | FZF session switcher                  |
| `prefix + M-1`    | Horizontal layout (leader 65% left)   |
| `prefix + M-2`    | Vertical layout (leader 60% top)      |
| `prefix + M-3`    | Tiled layout (equal sizes)            |
| `prefix + M-s`    | Capture current pane to file          |
| `prefix + M-a`    | Capture all panes to files            |
| `prefix + M-d`    | Full dashboard popup                  |
| `prefix + M-m`    | Memory system popup                   |
| `prefix + R`      | Reap dead agent panes                 |
| `prefix + S`      | Sync panes (toggle)                   |

### Claude Code Compatibility

| Setting             | Value    | Why                                                  |
| ------------------- | -------- | ---------------------------------------------------- |
| `allow-passthrough` | `on`     | DEC 2026 synchronized output — eliminates flicker    |
| `extended-keys`     | `on`     | TUI apps receive modifier key combos properly        |
| `escape-time`       | `0`      | No input delay                                       |
| `history-limit`     | `250000` | Handles Claude Code's high output volume             |
| `set-clipboard`     | `on`     | Native OSC 52 clipboard (works across SSH + nesting) |
| `focus-events`      | `on`     | TUI focus tracking                                   |

### Plugins (via TPM)

| Plugin           | Purpose                                       |
| ---------------- | --------------------------------------------- |
| `tmux-sensible`  | Sensible defaults everyone agrees on          |
| `tmux-resurrect` | Persist sessions across restarts              |
| `tmux-continuum` | Auto-save every 15 min, auto-restore on start |
| `tmux-yank`      | System clipboard integration (OSC 52)         |
| `tmux-fzf`       | Fuzzy finder for sessions/windows/panes       |

### tmux Health Management

```bash
shipwright tmux doctor     # Check Claude Code compat + features
shipwright tmux install    # Install TPM + all plugins
shipwright tmux fix        # Auto-fix issues in running session
shipwright tmux reload     # Reload config
```

### Conventions

- Team windows: named `claude-<team-name>` (shows lambda icon in status bar)
- Pane titles: `<team>-<role>` (visible in pane borders via pane-border-status)
- Set pane title: `printf '\033]2;agent-name\033\\'`
- Prefix key: **Ctrl-a**
- Adapter uses pane IDs (not indices) to avoid the pane-base-index bug

## Architecture

All scripts are bash (except the dashboard server in TypeScript). Grouped by layer:

### Core Scripts

<!-- AUTO:core-scripts -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-activity.sh` | 480 | Live agent activity stream |
| `scripts/sw-adaptive.sh` | 941 | data-driven pipeline tuning |
| `scripts/sw-adversarial.sh` | 259 | Adversarial Agent Code Review |
| `scripts/sw-architecture-enforcer.sh` | 319 | Living Architecture Model & Enforcer |
| `scripts/sw-auth.sh` | 610 | GitHub OAuth Authentication |
| `scripts/sw-autonomous.sh` | 1057 | Master controller for AI-building-AI loop |
| `scripts/sw-changelog.sh` | 696 | Automated Release Notes & Migration Guides |
| `scripts/sw-checkpoint.sh` | 605 | Save and restore agent state mid-stage |
| `scripts/sw-ci.sh` | 589 | GitHub Actions CI/CD Orchestration |
| `scripts/sw-cleanup.sh` | 350 | Clean up orphaned Claude team sessions & artifacts |
| `scripts/sw-code-review.sh` | 699 | Clean Code & Architecture Analysis |
| `scripts/sw-connect.sh` | 624 | Sync local state to team dashboard |
| `scripts/sw-context.sh` | 600 | Context Engine for Pipeline Stages |
| `scripts/sw-cost.sh` | 1070 | Token Usage & Cost Intelligence |
| `scripts/sw-daemon.sh` | 1420 | Autonomous GitHub Issue Watcher |
| `scripts/sw-dashboard.sh` | 510 | Fleet Command Dashboard |
| `scripts/sw-db.sh` | 1939 | SQLite Persistence Layer |
| `scripts/sw-decide.sh` | 691 | Shipwright Autonomous Decision Engine |
| `scripts/sw-decompose.sh` | 864 | Intelligent Issue Decomposition |
| `scripts/sw-deps.sh` | 533 | Automated Dependency Update Management |
| `scripts/sw-developer-simulation.sh` | 239 | Multi-Persona Developer Simulation |
| `scripts/sw-discovery.sh` | 910 | Cross-Pipeline Real-Time Learning |
| `scripts/sw-doc-fleet.sh` | 815 | Documentation Fleet Orchestrator |
| `scripts/sw-docs-agent.sh` | 525 | Auto-sync README, wiki, API docs |
| `scripts/sw-docs.sh` | 626 | Documentation Keeper |
| `scripts/sw-doctor.sh` | 1636 | Validate Shipwright setup |
| `scripts/sw-dora.sh` | 605 | DORA Metrics Dashboard with Engineering Intelligence |
| `scripts/sw-durable.sh` | 708 | Durable Workflow Engine |
| `scripts/sw-e2e-orchestrator.sh` | 535 | Test suite registry & execution |
| `scripts/sw-event-schema-sync.sh` | 93 | keep config/event-schema.json in step |
| `scripts/sw-eventbus.sh` | 415 | Durable event bus for real-time inter-component |
| `scripts/sw-evidence.sh` | 1101 | Machine-Verifiable Proof for Agent Deliveries |
| `scripts/sw-feedback.sh` | 999 | Production Feedback Loop |
| `scripts/sw-fix.sh` | 474 | Bulk Fix Across Multiple Repos |
| `scripts/sw-fleet-discover.sh` | 550 | Auto-Discovery from GitHub Orgs |
| `scripts/sw-fleet-viz.sh` | 411 | Multi-Repo Fleet Visualization |
| `scripts/sw-fleet.sh` | 1377 | Multi-Repo Daemon Orchestrator |
| `scripts/sw-guild.sh` | 556 | Knowledge Guilds & Cross-Team Learning |
| `scripts/sw-heartbeat.sh` | 316 | File-based agent heartbeat protocol |
| `scripts/sw-hello.sh` | 67 | Hello World Command |
| `scripts/sw-hygiene.sh` | 724 | Repository Organization & Cleanup |
| `scripts/sw-incident.sh` | 1132 | Autonomous Incident Detection & Response |
| `scripts/sw-init.sh` | 871 | Complete setup for Shipwright + Shipwright |
| `scripts/sw-instrument.sh` | 691 | Pipeline Instrumentation & Feedback Loops |
| `scripts/sw-intelligence.sh` | 1548 | AI-Powered Analysis & Decision Engine |
| `scripts/sw-jira.sh` | 628 | Jira ↔ GitHub Bidirectional Sync |
| `scripts/sw-launchd.sh` | 703 | Process supervision (macOS + Linux) |
| `scripts/sw-linear.sh` | 643 | Linear ↔ GitHub Bidirectional Sync |
| `scripts/sw-logs.sh` | 353 | View and search agent pane logs |
| `scripts/sw-loop.sh` | 2713 | Continuous agent loop harness for Claude Code |
| `scripts/sw-memory.sh` | 2241 | Persistent Learning & Context System |
| `scripts/sw-mission-control.sh` | 473 | Terminal-based pipeline mission control |
| `scripts/sw-model-router.sh` | 1056 | Intelligent Model Routing & Cost Optimization |
| `scripts/sw-otel.sh` | 609 | OpenTelemetry Observability |
| `scripts/sw-oversight.sh` | 757 | Quality Oversight Board |
| `scripts/sw-patrol-meta.sh` | 780 | Shipwright Self-Improvement Patrol |
| `scripts/sw-pipeline-composer.sh` | 444 | Dynamic Pipeline Composition |
| `scripts/sw-pipeline-vitals.sh` | 1076 | Pipeline Vitals Engine |
| `scripts/sw-pipeline.sh` | 279 | Autonomous Feature Delivery (Idea → Production) |
| `scripts/sw-pm.sh` | 749 | Autonomous PM Agent for Team Orchestration |
| `scripts/sw-pr-lifecycle.sh` | 688 | Autonomous PR Management |
| `scripts/sw-predictive.sh` | 834 | Predictive & Proactive Intelligence |
| `scripts/sw-prep.sh` | 1831 | Repository Preparation for Agent Teams |
| `scripts/sw-ps.sh` | 156 | Show running agent process status |
| `scripts/sw-public-dashboard.sh` | 797 | Public real-time pipeline progress |
| `scripts/sw-quality.sh` | 676 | Intelligent completion, audits, zero auto |
| `scripts/sw-reaper.sh` | 384 | Automatic tmux pane cleanup when agents exit |
| `scripts/sw-recruit.sh` | 495 | AGI-Level Agent Recruitment & Talent Management |
| `scripts/sw-regression.sh` | 632 | Regression Detection Pipeline |
| `scripts/sw-release-manager.sh` | 721 | Autonomous Release Pipeline |
| `scripts/sw-release.sh` | 701 | Release train automation |
| `scripts/sw-remote.sh` | 670 | Machine Registry & Remote Daemon Management |
| `scripts/sw-replay.sh` | 542 | Pipeline run replay, timeline viewing, narratives |
| `scripts/sw-retro.sh` | 820 | Sprint Retrospective Engine |
| `scripts/sw-review-rerun.sh` | 222 | Canonical Rerun Comment Writer |
| `scripts/sw-scale.sh` | 609 | Dynamic agent team scaling during pipeline execution |
| `scripts/sw-security-audit.sh` | 510 | Comprehensive Security Auditing |
| `scripts/sw-self-optimize.sh` | 1690 | Learning & Self-Tuning System |
| `scripts/sw-session.sh` | 553 | Launch a Claude Code team session in a new tmux window |
| `scripts/sw-setup.sh` | 376 | Comprehensive onboarding wizard |
| `scripts/sw-stall-detector.sh` | 406 | Pipeline Stall & Deadlock Detection |
| `scripts/sw-standup.sh` | 721 | Automated Daily Standups for AI Agent Teams |
| `scripts/sw-status.sh` | 869 | Dashboard showing Claude Code team status |
| `scripts/sw-strategic.sh` | 943 | Strategic Intelligence Agent |
| `scripts/sw-stream.sh` | 451 | Live terminal output streaming from agent panes |
| `scripts/sw-swarm.sh` | 684 | Dynamic agent swarm management |
| `scripts/sw-team-stages.sh` | 500 | Multi-agent execution with leader/specialist roles |
| `scripts/sw-templates.sh` | 228 | Browse and inspect team templates |
| `scripts/sw-test-all.sh` | 199 | Run every test suite, report the FULL result |
| `scripts/sw-testgen.sh` | 567 | Autonomous test generation and coverage maintenance |
| `scripts/sw-tmux-pipeline.sh` | 538 | Spawn and manage pipelines in tmux windows |
| `scripts/sw-tmux-role-color.sh` | 81 | Set pane border color by agent role |
| `scripts/sw-tmux-status.sh` | 151 | Status bar widgets for tmux |
| `scripts/sw-tmux.sh` | 625 | tmux Health & Plugin Management |
| `scripts/sw-trace.sh` | 480 | E2E Traceability (Issue → Commit → PR → Deploy) |
| `scripts/sw-tracker.sh` | 517 | Provider Router for Issue Tracker Integration |
| `scripts/sw-triage.sh` | 812 | Intelligent Issue Labeling & Prioritization |
| `scripts/sw-upgrade.sh` | 477 | Detect and apply updates from the repo |
| `scripts/sw-ux.sh` | 685 | Premium UX Enhancement Layer |
| `scripts/sw-webhook.sh` | 621 | GitHub Webhook Receiver for Instant Issue Processing |
| `scripts/sw-widgets.sh` | 528 | Embeddable Status Widgets |
| `scripts/sw-worktree.sh` | 421 | Git worktree management for multi-agent isolation |
| `scripts/sw` | 623 | CLI router — dispatches subcommands via exec |
<!-- /AUTO:core-scripts -->

### GitHub API Modules

<!-- AUTO:github-modules -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-github-app.sh` | 592 | GitHub App Management & Webhook Receiver |
| `scripts/sw-github-checks.sh` | 501 | Native GitHub Checks API Integration |
| `scripts/sw-github-deploy.sh` | 513 | Native GitHub Deployments API Integration |
| `scripts/sw-github-graphql.sh` | 969 | GitHub GraphQL API Client |
<!-- /AUTO:github-modules -->

### Issue Tracker Adapters

<!-- AUTO:tracker-adapters -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-linear.sh` | 643 | Linear ↔ GitHub Bidirectional Sync |
| `scripts/sw-jira.sh` | 628 | Jira ↔ GitHub Bidirectional Sync |
| `scripts/sw-tracker-linear.sh` | 568 | do not call directly |
| `scripts/sw-tracker-jira.sh` | 474 | do not call directly |
<!-- /AUTO:tracker-adapters -->

### Shared Libraries

| File                    | Lines | Purpose                            |
| ----------------------- | ----: | ---------------------------------- |
| `scripts/lib/compat.sh` |     — | Cross-platform compatibility shims |

### Test Suites

<!-- AUTO:test-suites -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-activity-test.sh` | 219 | Validate live agent activity stream |
| `scripts/sw-adapters-test.sh` | 197 | Structural/smoke tests for terminal & deploy |
| `scripts/sw-adaptive-model-test.sh` | 417 | Test Suite for Adaptive Model Selection |
| `scripts/sw-adaptive-test.sh` | 206 | Validate data-driven pipeline tuning |
| `scripts/sw-adaptive-timeout-test.sh` | 406 | Test Suite for Adaptive Stage Timeout Engine |
| `scripts/sw-adversarial-review-test.sh` | 266 | Adversarial Review Stage Tests |
| `scripts/sw-adversarial-test.sh` | 258 | Validate adversarial agent code review |
| `scripts/sw-agi-roadmap-test.sh` | 857 | Tests every feature we implemented |
| `scripts/sw-architecture-enforcer-test.sh` | 301 | Validate architecture model |
| `scripts/sw-auth-test.sh` | 141 | Validate OAuth authentication commands |
| `scripts/sw-auto-recovery-test.sh` | 208 | Auto Recovery System Test Suite |
| `scripts/sw-autonomous-e2e-test.sh` | 292 | Autonomous Loop E2E Test |
| `scripts/sw-autonomous-test.sh` | 207 | AI-building-AI master controller tests |
| `scripts/sw-autoresearch-e2e-test.sh` | 457 | Autoresearch RL System E2E Test Suite |
| `scripts/sw-bandit-selector-test.sh` | 410 | Bandit Selector Test Suite |
| `scripts/sw-budget-chaos-test.sh` | 251 | Budget Exhaustion & Chaos Tests |
| `scripts/sw-changelog-test.sh` | 201 | Validate release notes generation |
| `scripts/sw-chaos-test.sh` | 384 | Fault injection & recovery validation |
| `scripts/sw-checkpoint-test.sh` | 341 | Validate checkpoint save/restore |
| `scripts/sw-ci-test.sh` | 198 | GitHub Actions CI/CD orchestration tests |
| `scripts/sw-cleanup-test.sh` | 168 | Clean up orphaned sessions & artifacts |
| `scripts/sw-code-review-test.sh` | 175 | Clean code & architecture analysis tests |
| `scripts/sw-connect-test.sh` | 822 | Validate dashboard connection, heartbeat |
| `scripts/sw-constitutional-test.sh` | 320 | Constitutional AI Test Suite |
| `scripts/sw-context-budget-test.sh` | 335 | Context Window Budget Monitor tests |
| `scripts/sw-context-test.sh` | 219 | Context Engine for Pipeline Stages tests |
| `scripts/sw-convergence-test.sh` | 324 | Unit tests for convergence detection |
| `scripts/sw-cost-optimizer-test.sh` | 466 | Test suite for cost optimization |
| `scripts/sw-cost-test.sh` | 234 | Validate token usage & cost intelligence |
| `scripts/sw-daemon-test.sh` | 1985 | Unit tests for daemon metrics, health, alerting |
| `scripts/sw-dashboard-e2e-test.sh` | 591 | full live validation |
| `scripts/sw-dashboard-test.sh` | 250 | validates dashboard structure |
| `scripts/sw-db-test.sh` | 971 | SQLite Persistence Layer Test Suite |
| `scripts/sw-decide-test.sh` | 519 | Unit tests for the Autonomous Decision Engine |
| `scripts/sw-decompose-test.sh` | 221 | Intelligent Issue Decomposition tests |
| `scripts/sw-deps-test.sh` | 165 | Automated Dependency Update Management tests |
| `scripts/sw-developer-simulation-test.sh` | 262 | Validate multi-persona |
| `scripts/sw-discovery-test.sh` | 268 | Cross-Pipeline Real-Time Learning tests |
| `scripts/sw-doc-fleet-test.sh` | 344 | Validate documentation fleet operations |
| `scripts/sw-docs-agent-test.sh` | 182 | Validate documentation agent operations |
| `scripts/sw-docs-test.sh` | 781 | Validate documentation keeper, AUTO sections, |
| `scripts/sw-doctor-test.sh` | 420 | Validate setup diagnostics |
| `scripts/sw-dod-scorecard-test.sh` | 434 | Machine-Verifiable DoD Scorecard Tests |
| `scripts/sw-dora-test.sh` | 241 | Validate DORA metrics dashboard, DX metrics, |
| `scripts/sw-durable-test.sh` | 221 | Validate durable workflow engine |
| `scripts/sw-e2e-integration-test.sh` | 352 | Real Claude + Real GitHub |
| `scripts/sw-e2e-orchestrator-test.sh` | 157 | Test suite registry & execution |
| `scripts/sw-e2e-smoke-test.sh` | 835 | Pipeline orchestration without API keys |
| `scripts/sw-e2e-system-test.sh` | 497 | Proves full daemon→pipeline→loop→PR flow |
| `scripts/sw-eventbus-test.sh` | 155 | Durable event bus tests |
| `scripts/sw-evidence-test.sh` | 416 | Unit tests for sw-evidence.sh |
| `scripts/sw-feedback-test.sh` | 302 | Production Feedback Loop tests |
| `scripts/sw-fix-test.sh` | 619 | Unit tests for bulk fix across repos |
| `scripts/sw-fleet-discover-test.sh` | 274 | Validate GitHub org auto-discovery, |
| `scripts/sw-fleet-test.sh` | 822 | Unit tests for fleet orchestration |
| `scripts/sw-fleet-viz-test.sh` | 278 | Validate fleet visualization dashboard, |
| `scripts/sw-formal-spec-test.sh` | 297 | Formal Specification System Test Suite |
| `scripts/sw-frontier-test.sh` | 574 | Validate adversarial review, developer |
| `scripts/sw-github-app-test.sh` | 145 | Validate GitHub App management |
| `scripts/sw-github-checks-test.sh` | 535 | Validate Checks API wrapper |
| `scripts/sw-github-deploy-test.sh` | 523 | Validate Deployments API wrapper |
| `scripts/sw-github-graphql-test.sh` | 661 | Unit tests for GitHub GraphQL client |
| `scripts/sw-guild-test.sh` | 149 | Knowledge guilds & cross-team learning tests |
| `scripts/sw-heartbeat-test.sh` | 581 | Validate heartbeat lifecycle, |
| `scripts/sw-hello-test.sh` | 108 | Hello Command Test Suite |
| `scripts/sw-hygiene-test.sh` | 198 | Repository Organization & Cleanup tests |
| `scripts/sw-incident-test.sh` | 442 | Validate incident detection & response |
| `scripts/sw-init-test.sh` | 654 | E2E validation of init/setup flow |
| `scripts/sw-instrument-test.sh` | 172 | Pipeline instrumentation & feedback loops |
| `scripts/sw-integration-claude-test.sh` | 106 | Budget-limited real Claude smoke |
| `scripts/sw-intelligence-test.sh` | 534 | Unit tests for intelligence core |
| `scripts/sw-intent-analysis-test.sh` | 443 | Test suite for intent analysis module |
| `scripts/sw-jira-test.sh` | 284 | Validate Jira ↔ GitHub bidirectional sync |
| `scripts/sw-launchd-test.sh` | 899 | Validate service management on |
| `scripts/sw-lib-audit-trail-test.sh` | 311 |  |
| `scripts/sw-lib-compat-test.sh` | 357 | Unit tests for cross-platform helpers |
| `scripts/sw-lib-compound-audit-test.sh` | 281 |  |
| `scripts/sw-lib-daemon-dispatch-test.sh` | 421 | Unit tests for spawn/reap/queue |
| `scripts/sw-lib-daemon-failure-test.sh` | 213 | Unit tests for failure handling |
| `scripts/sw-lib-daemon-patrol-test.sh` | 343 | Unit tests for all patrol functions |
| `scripts/sw-lib-daemon-poll-test.sh` | 344 | Unit tests for poll, health, cleanup |
| `scripts/sw-lib-daemon-state-test.sh` | 383 | Unit tests for state management |
| `scripts/sw-lib-daemon-triage-test.sh` | 267 | Unit tests for triage scoring |
| `scripts/sw-lib-error-actionability-test.sh` | 213 |  |
| `scripts/sw-lib-helpers-test.sh` | 229 | Unit tests for shared helper functions |
| `scripts/sw-lib-pipeline-detection-test.sh` | 391 | Unit tests for detection fns |
| `scripts/sw-lib-pipeline-intelligence-test.sh` | 410 | Unit tests for intelligence |
| `scripts/sw-lib-pipeline-quality-checks-test.sh` | 193 | Unit tests for quality |
| `scripts/sw-lib-pipeline-stages-test.sh` | 290 | Unit tests for stage functions |
| `scripts/sw-lib-pipeline-state-test.sh` | 309 | Unit tests for pipeline state |
| `scripts/sw-linear-test.sh` | 300 | Validate Linear ↔ GitHub bidirectional sync |
| `scripts/sw-logs-test.sh` | 281 | Validate agent pane log viewing, searching, |
| `scripts/sw-loop-test.sh` | 911 | Validate continuous agent loop harness |
| `scripts/sw-memory-discovery-e2e-test.sh` | 411 | Memory & Discovery E2E Test |
| `scripts/sw-memory-effectiveness-test.sh` | 495 | Unit tests |
| `scripts/sw-memory-test.sh` | 898 | Unit tests for memory system & cost tracking |
| `scripts/sw-mission-control-test.sh` | 153 | Validate mission control dashboard |
| `scripts/sw-model-router-test.sh` | 313 | Intelligent model routing & optimization |
| `scripts/sw-mutation-executor-test.sh` | 309 | Mutation Testing Engine Test Suite |
| `scripts/sw-otel-test.sh` | 146 | OpenTelemetry observability |
| `scripts/sw-outcome-feedback-test.sh` | 430 | Unit tests for review capture & quality |
| `scripts/sw-oversight-test.sh` | 164 | Quality oversight board tests |
| `scripts/sw-patrol-meta-test.sh` | 449 | Validate self-improvement patrol |
| `scripts/sw-pipeline-composer-test.sh` | 632 | Test Suite |
| `scripts/sw-pipeline-test.sh` | 1964 | E2E validation invoking the REAL pipeline |
| `scripts/sw-pipeline-vitals-test.sh` | 226 | Validate pipeline health scoring |
| `scripts/sw-pm-test.sh` | 225 | Autonomous PM Agent test suite |
| `scripts/sw-policy-e2e-test.sh` | 290 | Verify config/policy.json is honored |
| `scripts/sw-policy-learner-test.sh` | 359 | Policy Learner Test Suite |
| `scripts/sw-pr-lifecycle-test.sh` | 317 | Validate autonomous PR management |
| `scripts/sw-predictive-test.sh` | 691 | Unit tests for predictive intelligence |
| `scripts/sw-prep-test.sh` | 636 | Validate repo preparation |
| `scripts/sw-process-reward-test.sh` | 252 | Process Reward Model Test Suite |
| `scripts/sw-project-detect-test.sh` | 434 | Unit tests for project detection |
| `scripts/sw-ps-test.sh` | 296 | Validate agent process status display |
| `scripts/sw-public-dashboard-test.sh` | 165 | Validate public dashboard generation |
| `scripts/sw-quality-profile-test.sh` | 447 | Unit tests for quality profile library |
| `scripts/sw-quality-test.sh` | 227 | Validate ruthless quality validation engine |
| `scripts/sw-reaper-test.sh` | 232 | Validate automatic tmux pane cleanup |
| `scripts/sw-recruit-test.sh` | 1395 | Test suite for AGI-level agent recruitment system |
| `scripts/sw-regression-test.sh` | 258 | Validate regression detection pipeline |
| `scripts/sw-release-manager-test.sh` | 206 | Validate release pipeline |
| `scripts/sw-release-test.sh` | 200 | Release train automation |
| `scripts/sw-remote-test.sh` | 396 | Validate machine registry, atomic writes, |
| `scripts/sw-replay-test.sh` | 167 | Pipeline run replay & timeline viewing |
| `scripts/sw-retro-test.sh` | 171 | Sprint retrospective engine tests |
| `scripts/sw-review-rerun-test.sh` | 317 | SHA-deduped rerun comment writer |
| `scripts/sw-reward-aggregator-test.sh` | 355 | Reward Aggregator Test Suite |
| `scripts/sw-rl-optimizer-test.sh` | 350 | RL Optimizer Test Suite (Phase 7) |
| `scripts/sw-root-cause-test.sh` | 374 |  |
| `scripts/sw-scale-test.sh` | 151 | Dynamic agent team scaling |
| `scripts/sw-scope-enforcement-test.sh` | 441 | Test suite for scope enforcement |
| `scripts/sw-security-audit-test.sh` | 162 | Security auditing tests |
| `scripts/sw-self-optimize-test.sh` | 837 | Unit tests for learning & tuning system |
| `scripts/sw-server-api-test.sh` | 713 | Dashboard Server API Test Suite |
| `scripts/sw-session-restart-test.sh` | 520 | Intelligent restart briefing system |
| `scripts/sw-session-test.sh` | 586 | E2E validation of session creation flow |
| `scripts/sw-setup-test.sh` | 262 | Validate comprehensive onboarding wizard |
| `scripts/sw-spec-driven-test.sh` | 218 | Specification-Driven Development Test Suite |
| `scripts/sw-spec-pipeline-test.sh` | 463 | Spec-Driven Pipeline Stages Test Suite |
| `scripts/sw-stall-detector-test.sh` | 367 | Validate stall detection and abort |
| `scripts/sw-standup-test.sh` | 241 | Validate daily standup automation |
| `scripts/sw-status-test.sh` | 294 | Validate status dashboard and --json output |
| `scripts/sw-strategic-test.sh` | 220 | Validate strategic intelligence agent |
| `scripts/sw-stream-test.sh` | 140 | Live terminal output streaming |
| `scripts/sw-swarm-test.sh` | 153 | Dynamic agent swarm management tests |
| `scripts/sw-team-stages-test.sh` | 148 | Validate multi-agent stage execution |
| `scripts/sw-templates-test.sh` | 251 | Validate team template browser |
| `scripts/sw-test-holdout-test.sh` | 214 | Test Holdout System Test Suite |
| `scripts/sw-test-optimizer-test.sh` | 395 | Test suite for test execution optimizer |
| `scripts/sw-testgen-test.sh` | 160 | Test generation & coverage tests |
| `scripts/sw-tmux-pipeline-test.sh` | 187 | Validate tmux pipeline management |
| `scripts/sw-tmux-test.sh` | 746 | Validate tmux doctor, install, fix, reload, |
| `scripts/sw-trace-test.sh` | 143 | E2E traceability (Issue → Commit → PR → Deploy) |
| `scripts/sw-tracker-providers-test.sh` | 552 | Unit tests for GitHub, Linear, |
| `scripts/sw-tracker-test.sh` | 534 | Validate tracker router, providers, and |
| `scripts/sw-triage-test.sh` | 249 | Intelligent Issue Labeling & Prioritization |
| `scripts/sw-upgrade-test.sh` | 334 | Validate upgrade detection and apply |
| `scripts/sw-ux-test.sh` | 185 | Validate UX enhancement layer |
| `scripts/sw-webhook-test.sh` | 167 | GitHub Webhook Receiver tests |
| `scripts/sw-widgets-test.sh` | 357 | Validate embeddable status widgets |
| `scripts/sw-worktree-test.sh` | 148 | Git worktree management for agent isolation |
<!-- /AUTO:test-suites -->

### Dashboard & Infra

| File                   | Lines | Purpose                            |
| ---------------------- | ----: | ---------------------------------- |
| `dashboard/server.ts`  |  3501 | Bun WebSocket dashboard server     |
| `dashboard/public/`    |     — | Dashboard frontend (HTML/CSS/JS)   |
| `install.sh`           |   755 | Interactive installer              |
| `templates/pipelines/` |     — | 8 pipeline template JSON files     |
| `tmux/templates/`      |     — | 25 team composition JSON templates |

### Runtime State and Artifacts

<!-- AUTO:runtime-state -->

- Pipeline state: `.claude/pipeline-state.md`
- Pipeline artifacts: `.claude/pipeline-artifacts/`
- Composed pipeline: `.claude/pipeline-artifacts/composed-pipeline.json`
- Events log: `~/.shipwright/events.jsonl`
- Daemon config: `.claude/daemon-config.json`
- Fleet config: `.claude/fleet-config.json`
- Heartbeats: `~/.shipwright/heartbeats/<job-id>.json`
- Checkpoints: `.claude/pipeline-artifacts/checkpoints/`
- Machine registry: `~/.shipwright/machines.json`
- Cost data: `~/.shipwright/costs.json, ~/.shipwright/budget.json`
- Intelligence cache: `.claude/intelligence-cache.json`
- Optimization data: `~/.shipwright/optimization/`
- Baselines: `~/.shipwright/baselines/`
- Architecture models: `~/.shipwright/memory/<repo-hash>/architecture.json`
- Team config: `~/.shipwright/team-config.json`
- Developer registry: `~/.shipwright/developer-registry.json`
- Team events: `~/.shipwright/team-events.jsonl`
- Invite tokens: `~/.shipwright/invite-tokens.json`
- Connect PID: `~/.shipwright/connect.pid`
- Connect log: `~/.shipwright/connect.log`
- GitHub cache: `~/.shipwright/github-cache/`
- Check run IDs: `.claude/pipeline-artifacts/check-run-ids.json`
- Deployment tracking: `.claude/pipeline-artifacts/deployment.json`
- Error log: `.claude/pipeline-artifacts/error-log.jsonl`
<!-- /AUTO:runtime-state -->

## GitHub Integration

The pipeline uses native GitHub APIs for CI integration, deployment tracking, and intelligent reviewer selection.

### GitHub API Modules

- **GraphQL Client** (`sw-github-graphql.sh`): Cached queries for file change frequency, blame data, contributors, similar issues, commit history, branch protection, CODEOWNERS, security alerts, Dependabot alerts, and Actions run history. All intelligence modules call through this layer.
- **Checks API** (`sw-github-checks.sh`): Creates native GitHub Check Runs per pipeline stage (visible in PR timeline). Replaces comment-based stage tracking with first-class GitHub UI integration.
- **Deployments API** (`sw-github-deploy.sh`): Tracks deployments per environment (staging/production). Enables rollback, deployment history, and environment state tracking.

### Pipeline Integration

- **Stage tracking**: Each pipeline stage creates/updates a GitHub Check Run (in addition to existing comment-based tracking)
- **Deployment tracking**: Deploy stage creates GitHub Deployment objects with status updates
- **Reviewer selection**: PR stage routes reviews to CODEOWNERS first, then top contributors, with auto-approve fallback
- **Branch protection**: Merge stage checks required reviews and status checks before attempting auto-merge
- **Intelligence enrichment**: All intelligence modules receive GitHub context (security alerts, contributor data, CI history, file churn)
- **Patrol enhancement**: Security patrol enriched with CodeQL + Dependabot alert data
- **Doctor checks**: Section 13 validates GitHub API access, scopes, GraphQL, and module installation

## Intelligence Layer

Intelligence defaults to **auto** (enabled when Claude CLI is available). Configure in `.claude/daemon-config.json` under the `intelligence` key; set `intelligence.enabled=false` to explicitly disable.

### Feature Flags

<!-- AUTO:feature-flags -->

| Flag | Default | Purpose |
| --- | --- | --- |
| `intelligence.cache_ttl_seconds` | `3600` | |
| `intelligence.adversarial_enabled` | `false` | |
| `intelligence.simulation_enabled` | `false` | |
| `intelligence.architecture_enabled` | `false` | |
| `intelligence.ab_test_ratio` | `0.2` | |
| `intelligence.anomaly_threshold` | `3.0` | |
<!-- /AUTO:feature-flags -->

### Modules

- **Intelligence Engine** (`sw-intelligence.sh`): Analyzes codebase structure, file change frequency, and test coverage to produce a cached analysis used by other modules.
- **Pipeline Composer** (`sw-pipeline-composer.sh`): Generates custom pipeline configurations by adjusting stage timeouts, iteration counts, and model routing based on intelligence output.
- **Self-Optimize** (`sw-self-optimize.sh`): Reads DORA metrics (lead time, deployment frequency, CFR, MTTR) and adjusts daemon config to improve performance over time.
- **Predictive** (`sw-predictive.sh`): Scores incoming issues for risk, detects anomalies in pipeline metrics, and provides AI patrol summaries.
- **Adversarial Review** (`sw-adversarial.sh`): Runs a second-pass adversarial review looking for edge cases, security issues, and failure modes.
- **Developer Simulation** (`sw-developer-simulation.sh`): Simulates developer workflows (clone, install, build, test) to catch UX issues.
- **Architecture Enforcer** (`sw-architecture-enforcer.sh`): Validates changes against architecture rules (dependency direction, naming conventions, layer boundaries).

### Enabling

```json
{
  "intelligence": {
    "enabled": true,
    "composer_enabled": true,
    "prediction_enabled": true
  }
}
```

The daemon calls into the intelligence layer at spawn time. The `intelligence` and `predict` CLI commands can also be run standalone.

## Custom Agents

Specialized agent definitions in `.claude/agents/` are loaded automatically by Claude Code when agents are spawned:

| Agent                   | File                         | Purpose                                                                   |
| ----------------------- | ---------------------------- | ------------------------------------------------------------------------- |
| Shell Script Specialist | `shell-script-specialist.md` | Bash 3.2 rules, pipefail safety, atomic writes, test harness patterns     |
| Code Reviewer           | `code-reviewer.md`           | Review checklist, security, performance, architecture layer boundaries    |
| Test Specialist         | `test-specialist.md`         | Test harness conventions, mock patterns, PASS/FAIL counting, coverage     |
| DevOps Engineer         | `devops-engineer.md`         | GitHub Actions, pipeline workflows, GitHub API, worktree management       |
| Pipeline Agent          | `pipeline-agent.md`          | Build loop context, memory injection, architecture rules, file hotspots   |
| Doc Fleet Agent         | `doc-fleet-agent.md`         | Documentation fleet — audit, refactor, enhance docs (5 specialized roles) |

## Hooks

Repo-level hooks in `.claude/hooks/` fire on lifecycle events. Registered in `.claude/settings.json`.

| Hook                 | Trigger                          | Purpose                                                      |
| -------------------- | -------------------------------- | ------------------------------------------------------------ |
| `pre-tool-use.sh`    | Before Edit/Write on `.sh` files | Injects bash 3.2 compatibility reminder                      |
| `post-tool-use.sh`   | After Bash tool failures         | Captures error signatures to `error-log.jsonl`               |
| `session-started.sh` | On session start                 | Shows pipeline state, recent failures, active issues, budget |

### Hook Types

| Type    | How It Works                              | Use Case                               |
| ------- | ----------------------------------------- | -------------------------------------- |
| Command | Runs a shell command, stdin receives JSON | File validation, logging, blocking     |
| HTTP    | POSTs JSON to a URL                       | Dashboard updates, Slack notifications |
| Prompt  | LLM evaluates a yes/no question (Haiku)   | "Did tests pass?", "Is PR ready?"      |
| Agent   | Multi-turn LLM with tool access           | Verify codebase state, run smoke tests |

### Lifecycle Hooks

| Event                | Matcher   | Script                     | Purpose                                        |
| -------------------- | --------- | -------------------------- | ---------------------------------------------- |
| `WorktreeCreate`     | —         | `worktree-create.sh`       | Copy daemon config into new worktrees          |
| `WorktreeRemove`     | —         | `worktree-remove.sh`       | Clean up heartbeat files for removed worktrees |
| `InstructionsLoaded` | `compact` | `instructions-reloaded.sh` | Track post-compaction rule reloads             |
| `ConfigChange`       | —         | `config-change.sh`         | Signal daemon to hot-reload config             |

### Safety Hooks

- `PreToolUse` blocks `git push --no-verify` (exit code 2)
- `PostToolUse` auto-formats edited files with Prettier
- `PostToolUse` captures Bash errors to `error-log.jsonl`

## Documentation Keeper

Auto-sync documentation from source code using HTML comment markers (`AUTO:section-id` pairs). For autonomous multi-agent documentation work, use `shipwright doc-fleet` (5 specialized agents: audit, refactor, enhance).

```bash
shipwright docs check      # Report which sections are stale (exit 1 if any)
shipwright docs sync       # Regenerate all stale AUTO sections
shipwright docs wiki       # Generate/update GitHub wiki pages
shipwright docs report     # Show documentation freshness report
```

AUTO sections in `.claude/CLAUDE.md`: `core-scripts`, `github-modules`, `tracker-adapters`, `test-suites`, `feature-flags`, `runtime-state`. The daemon patrol auto-syncs stale sections. A GitHub Actions workflow (`shipwright-docs.yml`) runs on push to main and weekly.

## Context Engineering & Token Optimization

Efficient context window usage directly improves agent accuracy and reduces cost. These principles apply to all pipeline agents and interactive sessions.

### Core Principles

- **Filter before injecting** — Never dump raw tool output into context. Use `jq`, `grep`, `head`, or subagents to extract only relevant data before it enters the context window.
- **Batch independent tool calls** — Make parallel tool calls in a single turn. Each sequential round-trip adds overhead tokens from tool definitions and call/response framing.
- **Delegate data-heavy work to subagents** — Spawn Task subagents for large intermediate results (codebase searches, log analysis, multi-file reads). Only the final summary enters your context window.
- **Prefer targeted reads** — Read specific line ranges (`offset`/`limit`) instead of entire files. Use Grep with narrow patterns instead of reading files and searching manually.
- **Prune proactively** — Summarize completed work and discard intermediate artifacts before context gets tight. Don't wait for auto-compaction.
- **Keep inter-agent messages concise** — Verbose status updates bloat teammate context. Use structured, brief task updates.

### Pipeline-Specific Optimizations

- **Prompt composition** — The `compose_prompt` and `manage_context_window` functions should produce focused prompts. Include only the context the agent needs for the current iteration, not the full history.
- **Model routing** — Use `cost-aware` pipeline template to route cheaper models (haiku/sonnet) for simple stages (intake, formatting) and expensive models (opus) only for complex stages (design, review).
- **Iteration context** — Each loop iteration should carry forward only the summary of previous work, not full outputs. The convergence detector already tracks this — lean on it.
- **Memory injection** — The memory system injects learned patterns. Keep memory entries focused (root cause + fix), not verbose narratives.

### Programmatic Tool Calling (API)

When building features that call the Claude API directly (dashboard intelligence, recruit LLM calls), prefer programmatic tool calling over JSON tool definitions:

- Set `"allowed_callers": ["code_execution_20260120"]` on tools to let Claude write code to invoke them in a sandbox
- Intermediate results stay in the sandbox — only the final answer enters context
- Reduces token usage by ~37% and improves accuracy on multi-tool workflows
- Use `"type": "tool_search_tool_bm25_20251119"` with `"defer_loading": true` for large tool catalogs (85%+ token reduction)

### Web Search Optimization (API)

For any API calls using web search, use the dynamic filtering variant:

- Use `"type": "web_search_20260209"` (not the older `web_search_20250305`)
- Add beta header: `"anthropic-beta: code-execution-web-tools-2026-02-09"`
- Claude writes post-processing code to filter search results before they enter context
- 24% fewer input tokens, 11% accuracy improvement on search benchmarks

## MCP Configuration

### Environment Variables

| Variable                | Default | Purpose                                                     |
| ----------------------- | ------- | ----------------------------------------------------------- |
| `ENABLE_TOOL_SEARCH`    | `auto`  | Dynamic tool loading when definitions exceed 10% of context |
| `MAX_MCP_OUTPUT_TOKENS` | `50000` | Limit MCP tool output to prevent context flooding           |

### Managed MCP

Generate with `shipwright prep`:

```json
{
  "allowedMcpServers": ["*"],
  "deniedMcpServers": [],
  "note": "Configure MCP server access policies for pipeline agents"
}
```

Useful for fleet/daemon mode to restrict agent MCP access.

### File Suggestion

Custom `@` autocomplete via `scripts/shipwright-file-suggest.sh` surfaces Shipwright-specific files: pipeline state, daemon config, agent definitions, schemas, and recent loop logs.

## Development Guidelines

### Shell Standards

- All scripts use `set -euo pipefail`
- **Bash 3.2 compatible** — no `declare -A` (associative arrays), no `readarray`, no `${var,,}` (lowercase), no `${var^^}` (uppercase)
- `VERSION` variable at top of every script — keep in sync
- Event logging: `emit_event "type" "key=val" "key2=val2"` writes to `events.jsonl`

### Output Helpers

- `info()`, `success()`, `warn()`, `error()` — standardized output
- Boxed headers with Unicode box-drawing characters

### Colors

| Name  | Hex       | Usage                                |
| ----- | --------- | ------------------------------------ |
| Cyan  | `#00d4ff` | Primary accent, active borders, CTAs |
| Green | `#4ade80` | Success indicators                   |
| Amber | `#fbbf24` | Warning indicators                   |
| Rose  | `#f43f5e` | Error indicators                     |

Purple (`#7c3aed`) and Blue (`#0066ff`) are used only as gradient endpoints, never as standalone accents.

### Common Pitfalls

- `grep -c || echo "0"` under pipefail produces double output — use `|| true` + `${var:-0}`
- `cmd | while read` loses variable state (subshell) — use `while read; done < <(cmd)`
- Atomic file writes: use tmp file + `mv`, not direct `echo > file`
- JSON in bash: use `jq --arg` for proper escaping, never string interpolation
- `cd` in helper functions changes caller's directory — use subshells `( cd dir && ... )`
- Check `$NO_GITHUB` in any new GitHub API features

## Maintainer / Release (which script to call)

**Prefer the CLI** so tooling and agents always use the same entry points:

| Task                                           | CLI (preferred)                   | Script (if not using CLI)              |
| ---------------------------------------------- | --------------------------------- | -------------------------------------- |
| Bump version everywhere                        | `shipwright version bump <x.y.z>` | `scripts/update-version.sh <x.y.z>`    |
| Verify version consistency                     | `shipwright version check`        | `scripts/check-version-consistency.sh` |
| Build release tarballs                         | `shipwright release build`        | `scripts/build-release.sh`             |
| Release train (tag, changelog, GitHub release) | `shipwright release publish`      | `scripts/sw-release.sh publish`        |

- **Canonical version**: `package.json` → `version`. All script `VERSION=`, README badge, and (at build time) website footer derive from it after a bump.
- **Before release**: Run `shipwright version check` (CI does this). Then bump with `shipwright version bump <x.y.z>`, add a `[x.y.z]` section to `CHANGELOG.md`, then `shipwright release publish` or tag and push for the release workflow.
- **Packaging**: `scripts/build-release.sh` is invoked by `.github/workflows/release.yml` on tag push; it reads version from `package.json` and creates `dist/shipwright-{platform}.tar.gz` and checksums. npm publish and Homebrew tap update are separate steps (see README/CHANGELOG).

## Setup & validation (everything working)

- **`shipwright doctor`** — Validates prerequisites (tmux, jq, Node, Claude CLI), installed files (overlay, hooks), PATH, pane display, env vars, and (when run from the Shipwright repo) **version consistency** (package.json vs README vs scripts). Run after install or when debugging "is my setup correct?"
- **`shipwright version check`** — Exit 0 only if version is consistent everywhere; run in CI and before release. When in the Shipwright repo, `doctor` runs this automatically.
- **`shipwright setup`** — Guided setup (four phases); **`shipwright init`** — Quick setup with no prompts. Use one of these in a new environment before using pipeline/daemon/loop.

## Test Harness

```bash
# Run all pipeline tests (mock binaries, no real Claude/GitHub calls)
./scripts/sw-pipeline-test.sh

# Run all 102 test suites
npm test
```

See the AUTO:test-suites table above for the complete list of test suites registered in `package.json`.

Each test suite uses mock binaries in a temp directory, with PASS/FAIL counters, colored output, and ERR traps.
