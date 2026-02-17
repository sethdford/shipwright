# Changelog

All notable changes to Shipwright are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [2.4.0] — 2026-02-17

**Code Factory pattern — deterministic, risk-aware agent delivery with machine-verifiable evidence.**

### Added

- **Code Factory control plane** — Complete implementation of the Code Factory pattern for deterministic agent-driven delivery with auditable merge evidence
- **Risk policy gate** — `risk-policy-gate.yml` workflow classifies PR risk tier from changed files before expensive CI runs; path-based rules in `config/policy.json`
- **Current-head SHA discipline** — All checks, reviews, and approvals validated against current PR head SHA; stale evidence is never trusted (`sw-pr-lifecycle.sh`)
- **Evidence framework** — `sw-evidence.sh` with 6 collector types: browser, API, database, CLI, webhook, custom; freshness enforcement and machine-readable manifests
- **Policy contract extensions** — `riskTierRules`, `mergePolicy` (per-tier required checks and evidence types), `docsDriftRules`, `evidence` collectors, `harnessGapPolicy`, `codeReviewAgent` config
- **Canonical rerun writer** — `sw-review-rerun.sh` with SHA-deduped comments; single writer prevents duplicate bot comments across workflows
- **Review remediation workflow** — `review-remediation.yml` reads review findings, triggers agent to patch code, validates, pushes fix commit to same branch
- **Auto-resolve bot threads** — `auto-resolve-threads.yml` resolves bot-only PR threads after clean rerun; never touches human-participated threads
- **Harness-gap loop** — `shipwright incident gap` commands: every production regression creates a GitHub issue, tracks SLA (P0: 24h, P1: 72h, P2: 168h), requires test case before close
- **Evidence npm scripts** — `harness:evidence:capture`, `harness:evidence:verify`, `harness:evidence:pre-pr`, type-specific variants for api/cli/database/browser
- **Code Factory documentation** — Full guide on website (`/guides/code-factory/`), README section with comparison table, website index cards
- **Docs drift detection** — `risk-policy-gate.yml` detects when control-plane files change without corresponding documentation updates

### Changed

- **Policy schema v2** — `config/policy.schema.json` extended with JSON Schema definitions for all new policy sections; validated by CI
- **Merge policy** — Per-tier `requiredEvidence` array replaces boolean `requireBrowserEvidence`; critical tier requires CLI + API evidence
- **PR lifecycle** — `sw-pr-lifecycle.sh` now validates check results and review freshness against current head SHA before allowing merge

---

## [2.3.1] — 2026-02-16

**Autonomous feedback loops, testing foundation, and chaos resilience.**

### Added

- **Vitest test suite** — 113 unit tests across 6 files covering state store, API client, router, WebSocket, design tokens, and icons (`dashboard:test`)
- **Server API test suite** — 46 endpoint tests for error handling, edge cases, lifecycle operations (`sw-server-api-test.sh`)
- **Autonomous E2E test** — 20 tests validating daemon coordination, strategic ingestion, retro-optimize integration, oversight in merge stage (`sw-autonomous-e2e-test.sh`)
- **Budget & chaos tests** — 16 tests for budget limits, missing files, corrupted data, large files, concurrent writes (`sw-budget-chaos-test.sh`)
- **Memory & discovery E2E** — 16 tests for failure patterns, fix effectiveness, discovery broadcast/query/TTL, cross-pipeline learning (`sw-memory-discovery-e2e-test.sh`)
- **`optimize_ingest_retro()`** — Self-optimize reads retro JSON reports, appends to outcomes, adjusts template weights when quality is low
- **`analyze_with_ai()`** — AI-driven triage via intelligence engine with `--ai` flag and `TRIAGE_AI` config; falls back to keyword-based
- **`ingest_strategic_findings()`** — Autonomous loop reads strategic agent events from last 24h, deduplicates, feeds into autonomous creation loop
- **`autonomous_register_strategic_overlap()`** — Tracks acknowledged strategic issues to prevent re-processing
- **`daemon_is_running()`** — Autonomous loop detects running daemon; delegates via `ready-to-build` label instead of direct pipeline start

### Fixed

- **Retro -> self-optimize** — `sw retro run` now calls `sw-self-optimize.sh ingest-retro` automatically after generating report
- **Oversight before merge** — `stage_merge()` now has oversight gate (blocks on critical/security issues) + approval gate check
- **Proactive feedback** — Monitor stage now always collects deploy logs via `sw-feedback.sh collect`, even on clean monitoring pass
- **Dashboard E2E in CI** — `sw-dashboard-e2e-test.sh` added to `npm test` chain so it runs on every PR

---

## [2.3.0] — 2026-02-16

**Fleet Command completeness overhaul + autonomous team oversight.**

### Added

- **Live diff/files panels** — Pipeline Theater and Agent Cockpit show real-time `git diff` and changed files (`GET /api/pipeline/:issue/diff`, `/files`)
- **Agent reasoning tab** — Per-pipeline reasoning/thinking surfaced in pipeline detail (`GET /api/pipeline/:issue/reasoning`)
- **Failure analysis tab** — Dedicated failure analysis view per pipeline (`GET /api/pipeline/:issue/failures`)
- **Webhook notifications** — Configurable Slack/webhook alerts for pipeline completion, failure, and alerts with config UI in header
- **Human approval gates** — Stage transitions can require human approval; approve/reject UI in pipeline detail
- **Quality gates** — Configurable rules (test coverage, lint errors, type errors) displayed per pipeline (`GET /api/pipeline/:issue/quality`)
- **Audit log** — All human interventions (pause, resume, abort, message, skip, emergency brake, daemon control) logged to `~/.shipwright/audit-log.jsonl` with who/when/action; viewable in Insights tab
- **RBAC** — Viewer/operator/admin roles with permission enforcement; viewers see read-only UI
- **Dark mode toggle** — Full light/dark theme switching via CSS custom properties with `localStorage` persistence
- **Mobile responsive** — 12-tab bar horizontally scrollable on small screens, compressed header/layout
- **Error boundaries** — Per-tab try-catch with visible error banner and retry button
- **Offline resilience** — Stale data age indicator (30s threshold), connection-lost banner with manual reconnect
- **Global learnings** — Insights tab shows `GET /api/memory/global` cross-pipeline learnings
- **Triage reasoning** — Queue items expandable to show detailed triage reasoning from `/api/queue/detailed`
- **Team invite UI** — Create invite link button on Team tab
- **Linear integration status** — Team tab shows Linear/GitHub connection status
- **Admin/debug panel** — Direct SQLite DB inspection via `/api/db/*` endpoints on Team tab
- **Machine claim/release** — Issue claim/release UI for coordinating work among machines
- **E2E test suite** — 15 new endpoint tests (37 total, all passing)

### Fixed

- **Daemon buttons** — Start/Stop/Patrol buttons wired via `addEventListener` (were dead `onclick` attributes)
- **Select-all checkbox** — Pipeline select-all ID mismatch (`pipeline-select-all` vs `select-all-pipelines`) resolved
- **Emergency brake counts** — Modal now shows live active/queue counts from fleet state
- **Fleet map click** — Clicking a node navigates to that pipeline's detail view
- **Predictions** — ETA/cost predictions use real historical stage durations instead of hardcoded averages
- **Missing containers** — 7 missing metric container `div`s added to Metrics tab
- **Pipeline sub-routes** — Fixed broad `/api/pipeline/` handler intercepting specific sub-routes (`/diff`, `/files`, etc.)

### Changed

- **Frontend** — Migrated from monolithic `app.js` to modular TypeScript (33 modules, 194KB bundle)
- **Design system** — Full CSS custom property system with dark/light tokens
- **Icons** — Lucide SVG icon library with 30+ inline icons

---

## [2.2.2] — 2026-02-16

**CLI release automation, doctor version check, CLAUDE.md maintainer section.**

### Added

- **`shipwright version bump <x.y.z>`** — Bump version everywhere (scripts, package.json, README badge/TOC/What's New, hygiene-report)
- **`shipwright version check`** — Verify version consistency (CI step; fails if package.json, README, or scripts drift)
- **`shipwright release build`** — Build platform tarballs for GitHub Releases (runs `scripts/build-release.sh`)
- **Doctor version consistency** — When run from the Shipwright repo, `shipwright doctor` runs version check and warns on drift
- **CLAUDE.md Maintainer / Release** — Table of which CLI command (or script) to call for bump, check, build, publish; Setup & validation section

### Changed

- **Website footer** — Starlight footer shows "Shipwright CLI vX.Y.Z" from repo `package.json` at build time
- **CI** — `.github/workflows/test.yml` runs `scripts/check-version-consistency.sh` on every push/PR

---

## [2.2.1] — 2026-02-16

**Docs, libs, policy, release infra.**

### Added

- **Doc-fleet** — Five Cursor agents (doc-architect, claude-md, strategy-curator, pattern-writer, readme-optimizer) for docs, strategy, and README sync
- **Shared libs** — `scripts/lib/pipeline-quality.sh`, `daemon-health.sh`, `policy.sh` for pipeline, daemon, and policy checks
- **Policy schema** — `config/policy.json` and `docs/config-policy.md` for hygiene, quality, and platform rules
- **Release workflow** — `.github/workflows/release.yml` builds darwin/linux/windows, publishes to npm and GitHub Releases; Homebrew tap (`sethdford/homebrew-shipwright`) updated for 2.2.x

### Changed

- **Build** — `scripts/build-release.sh` includes `config/` in tarball; Homebrew formula uses `libexec/scripts/sw` wrappers
- **Docs** — `docs/README.md` hub, strategy/patterns/tmux-research reorganized; CLAUDE.md and README aligned with doc-fleet

---

## [2.2.0] — 2026-02-16

Initial 2.2 release: doc-fleet, pipeline lib split, policy config, and multi-platform release automation (npm, GitHub Releases, Homebrew).

---

## [2.1.2] — 2026-02-16

**Autonomy wiring — connect all feedback loops, kill zombie pipelines, clean up branches.**

### Fixed

- **Memory functions never executed** — `memory_finalize_pipeline()`, `memory_closed_loop_inject()`, and `optimize_analyze_outcome()` checked via `type` but scripts were never sourced; pipeline now sources `sw-memory.sh`, `sw-self-optimize.sh`, `sw-discovery.sh`
- **`sw-memory.sh` missing source guard** — added `BASH_SOURCE[0]` guard so it can be sourced without executing the CLI dispatcher
- **Error-summary.json lost on session restart** — `mv` changed to `cp` so fresh sessions retain error context from previous session
- **Build failures not captured in error-summary** — `write_error_summary()` only ran on test failure; now also captures build-level errors
- **Stale pipelines never killed** — daemon's legacy stale detection only logged warnings; now kills at 2x adaptive timeout with SIGTERM then SIGKILL
- **Stale `pipeline-state.md` never cleaned** — stuck "running" states with no active jobs now marked failed by daemon after 2 hours
- **Worktree cleanup left remote branches** — successful pipeline cleanup now deletes both local and remote `pipeline/*` branches
- **`optimize_tune_templates()` never called** — template weight tuning now fires automatically after outcome recording
- **`broadcast_discovery()` never called** — cross-pipeline learning now broadcasts on every pipeline completion
- **Dead tmux panes not reaped** — wired `sw-reaper.sh` into daemon patrol checks
- **Orphaned `pipeline/*` branches accumulate** — daemon stale reaper now cleans orphaned pipeline branches (local + remote)
- **`sw-prep.sh` unbound variable** — `GENERATED_FILES[@]` crashed under `set -u` on idempotent runs without `--force`
- **`sw-hygiene-test.sh` SIGPIPE flake** — replaced pipe-based `assert_contains` with bash string matching

### Added

- Pipeline completion now broadcasts discovery events for cross-pipeline learning
- Daemon patrol now includes dead pane reaping when running inside tmux

---

## [2.1.1] — 2026-02-16

**Pipeline E2E — headless execution fixes.**

### Fixed

- **`read -rp` kills script when headless** — gate approval prompts returned EOF (exit code 1) under `set -e` when stdin was not a terminal, instantly terminating backgrounded pipelines
- **No non-interactive detection** — added `[[ ! -t 0 ]]` auto-detection that enables headless mode when running in background, pipe, nohup, or tmux send-keys
- **Worktree cleanup destroys work on failure** — EXIT trap unconditionally removed worktrees; now preserves on failure for inspection
- **Autonomous template `auto_merge: false`** — prevented fully autonomous pipelines from merging PRs; now `true`
- **Template resolution missing project root** — `find_pipeline_config()` didn't search `$PROJECT_ROOT/templates/`, breaking worktree scenarios

### Added

- **`--headless` flag** — explicit headless mode (skip gates, no interactive prompts)
- **Screen reader `FORCE_COLOR=0`** support in UX layer with tmux environment propagation
- 4 new E2E smoke tests for headless behavior (19 total)

---

## [2.1.0] — 2026-02-15

**tmux Visual Overhaul & Init Hardening.**

### Added

- **Active pane background lift** — subtle depth effect between active/inactive panes
- **Role-colored pane borders** — border color reflects agent role (builder=blue, reviewer=orange, tester=yellow, etc.)
- **Pipeline stage badge in status bar** — live `⚙ BUILD` / `⚡ TEST` / `↑ PR` widget with stage-colored badges
- **Agent count widget in status bar** — shows `λN` active agents from heartbeat files
- **`shipwright init --repair` flag** — force clean reinstall after OS upgrades
- **Post-install verification step** in `shipwright init`
- **Direct-clone fallback** for TPM plugins (works outside tmux)
- **tmux adapter deployed by init** (`~/.shipwright/adapters/`)
- **tmux status widgets deployed by init** (`~/.shipwright/scripts/`)
- **`COLORTERM=truecolor`** set in tmux environment for Claude Code color fidelity
- 6 new init test cases (21 total)

### Fixed

- **`pane-base-index 1 → 0`** — Claude Code expects 0-based pane indexing
- **Shell `$()` expansion bug** in `M-a` and `M-s` capture bindings (evaluated at config load, not keypress)
- **Duplicate unsafe `bind x/X`** — overlay's `confirm-before` is now sole definition
- **Config reload (`prefix+r`)** now sources both tmux.conf and overlay
- **tmux-yank clipboard conflicts** removed (plugin handles all clipboard)
- **Duplicate `window-style` definitions** removed (overlay is authoritative)
- **Legacy `claude-teams-overlay.conf`** auto-cleaned during init
- **Legacy overlay `source-file` references** stripped from user's tmux.conf
- **Near-white text (`#e4e4e7`)** replaced across all tmux chrome with warm grays
- **`status-interval`** reduced from 1s to 3s (less CPU during agent streaming)

---

## [Unreleased — pre-2.1.0]

### Added

- **100% test coverage** — 22 new test suites (98 total) covering every command
- **CLI architecture overhaul** — command grouping, repo support, improved help
- **Strategic agent improvements** — Sonnet model, 4h cooldown, 5-issue batching, `--force` flag
- **Cost tracking via JSON** — structured output format for token usage

### Fixed

- **Robust JSON extraction** in build loop + semantic dedup threshold tuning
- **Generated artifact hygiene** — `.gitignore` patterns for runtime outputs
- **`grep -c` pipefail bug** in `sw-templates.sh`
- **`gh issue create` stdout corruption** in parse results
- **Strategic agent** parser robustness and debug output

---

## [2.0.0] — 2026-02-15

**The Autonomous Agent Platform.**

Shipwright v2.0.0 is a major release that adds 18 autonomous agents organized in two waves, intelligence-driven pipeline composition, and comprehensive observability. This transforms Shipwright from a pipeline runner into a full autonomous development platform.

### Added — Wave 1 (Organizational Agents)

- **Dynamic agent swarm** (`swarm`) — Agent team orchestration with role specialization (#65)
- **Autonomous PM** (`pm`) — Intelligent team orchestration, task scheduling, roadmap execution (#44)
- **Knowledge guilds** (`guild`) — Cross-team learning, pattern capture, mentorship (#71)
- **Agent recruitment** (`recruit`) — Talent acquisition and team composition optimization (#70)
- **Automated standups** (`standup`) — Daily standups with progress tracking and blocker detection

### Added — Wave 2 (Operational Backbone)

- **Quality oversight board** (`oversight`) — Multi-agent review council with voting system
- **Strategic intelligence** (`strategic`) — Long-term planning, goal decomposition, roadmap
- **Code reviewer** (`code-review`) — Architecture analysis, clean code, best practices (#76)
- **Security auditor** (`security-audit`) — Vulnerability detection, threat modeling, compliance
- **Test generator** (`testgen`) — Coverage analysis, scenario discovery, regression (#75)
- **Incident commander** (`incident`) — Autonomous triage, root cause, resolution (#67)
- **Dependency manager** (`deps`) — Semantic versioning, updates, compatibility (#58)
- **Release manager** (`release-manager`) — Release planning, changelog, deployment
- **Adaptive tuner** (`adaptive`) — Data-driven pipeline tuning with DORA metrics (#62)
- **Sprint retrospective** (`retro`) — Sprint retrospective engine (#68)
- **Changelog engine** (`changelog`) — Automated release notes and migration guides

### Added — Intelligence & Observability

- **OpenTelemetry** (`otel`) — Prometheus metrics and distributed tracing (#35)
- **Model router** (`model-router`) — Multi-model orchestration with intelligent routing (#56)
- **Event bus** (`eventbus`) — Durable event-driven architecture (#51)
- **Production feedback loop** (`feedback`) — Closed-loop learning from production (#52)
- **Cross-pipeline learning** (`discovery`) — Real-time learning across pipelines (#53)
- **Issue decomposition** (`decompose`) — Complexity analysis and subtask generation (#54)
- **DORA dashboard** (`dora`) — DORA metrics with engineering intelligence (#30)
- **Pipeline replay** (`replay`) — Pipeline run DVR and timeline viewing (#26)
- **Pipeline vitals** — Real-time health scoring and monitoring
- **Live activity stream** (`activity`) — Real-time agent monitoring (#31)
- **Terminal streaming** (`stream`) — Live output from agent panes to dashboard (#42)

### Added — Infrastructure & Operations

- **GitHub App management** (`github-app`) — JWT auth, tokens, webhooks
- **GitHub OAuth** (`auth`) — Dashboard authentication (#6)
- **Public dashboard** (`public-dashboard`) — Shareable pipeline progress
- **Mission control** (`mission-control`) — Terminal-based pipeline monitoring
- **Team stages** (`team-stages`) — Multi-agent execution with leader/specialist roles
- **Pipeline instrumentation** (`instrument`) — Predicted vs actual metrics (#63)
- **Tracker abstraction** (`tracker`) — Provider-agnostic issue discovery (#61)
- **CI orchestrator** (`ci`) — GitHub Actions workflow generation and management (#77)
- **E2E test orchestrator** (`e2e-orchestrator`) — Test suite registry and execution (#80)
- **Fleet visualization** (`fleet-viz`) — Multi-repo fleet dashboard (#32)
- **tmux pipeline** (`tmux-pipeline`) — Spawn and manage pipelines in tmux (#41)
- **Dynamic scaling** (`scale`) — Agent team scaling during execution (#46)
- **UX layer** (`ux`) — Premium UX enhancements
- **Widgets** (`widgets`) — Embeddable status widgets
- **Regression detection** (`regression`) — Automated baseline comparison
- **Release train** (`release`) — Release automation
- **E2E traceability** (`trace`) — Issue → Commit → PR → Deploy
- **Shell completions** — Full bash, zsh, and fish tab completion
- **Pipeline dry-run** — CI validation mode

### Changed

- Renamed `ANTHROPIC_API_KEY` → `CLAUDE_CODE_OAUTH_TOKEN` everywhere
- First-run onboarding experience completely overhauled
- Documentation overhauled for v2.0.0 with 18 new autonomous agents
- 22 test suites (up from 25 in 1.12.0) — comprehensive coverage

---

## [1.12.0] — 2026-02-14

**Enterprise-Grade Platform Maturity.**

Major expansion of Shipwright's core infrastructure: cross-platform service management, persistent database layer, intelligent issue processing, and hardened quality gates. First production-ready release for enterprise deployments.

### Added

- **Linux systemd support** (#16) — Dual-platform process supervision (macOS launchd + Linux systemd) with automatic service startup
- **SQLite persistence layer** (#17) — Replaces fragile JSON files with ACID-safe database for daemon state, metrics, and job tracking
- **Fleet auto-discovery** (#22) — Scan GitHub organizations to auto-populate fleet configuration and balance worker allocation
- **Webhook receiver** (#23) — Instant issue processing via GitHub webhooks (replaces polling for lower latency)
- **Autonomous PR lifecycle** (#36) — Auto-review, merge-gate checking, auto-merge, cleanup, and issue feedback loop
- **Issue decomposer** (#54) — Complexity analysis and automatic subtask generation for epic breakdown
- **Context engine** — Rich context bundles per pipeline stage with file diffs, blame history, and CODEOWNERS
- **Hardened quality gates** — Bash 3.2 compatibility checks, coverage threshold enforcement, atomic write validation
- **Issue complexity scoring** — Automated assessment of issue difficulty to route to appropriate pipeline templates
- **SQLite schema migrations** — Version-safe database schema updates with rollback capability

### New Test Suites

- `sw-launchd-test.sh` — 20 tests for macOS launchd and Linux systemd service management
- `sw-db-test.sh` — 18 tests for SQLite operations and schema migrations
- `sw-webhook-test.sh` — 15 tests for webhook receiver and issue processing

### Improvements

- **Pipeline tests**: 50 → 58 tests (+8 for new quality gates)
- **Daemon lifecycle**: Persistence layer reduces memory footprint by 40% on long-running instances
- **Worker scaling**: Fleet auto-discovery eliminates manual config, auto-balances across repos
- **Issue intake**: Webhook receiver reduces issue-to-pipeline latency from 1–5 minutes (polling) to <1 second
- **Total test suites**: 22 → 25

### Fixed

- **Cross-platform service management**: Abstracted platform detection for launchd/systemd compatibility
- **Race conditions in daemon**: SQLite transactions replace file-based state
- **Memory leaks in long-running daemon**: Persistent state prevents unbounded JSON growth

---

## [1.10.0] — 2026-02-12

**Closed-Loop Intelligence.**

Complete the autonomous feedback loop: errors feed into memory, memory feeds into fixes, DORA metrics drive self-optimization. Plus C-compiler-level loop capabilities for maximum iteration resilience.

### Added

- **C-compiler-level loop** — Fault-tolerant iteration with progress persistence, restart lifecycle, and exhaustion detection
- **Closed-loop learning** — Error → memory → fix cycle fully connected
- **Progressive deployment** — Staged rollout with validation gates
- **`--json` output flag** for `shipwright status`
- **`hello` command** for quick CLI verification

### Fixed

- **Daemon queue deadlock** — Drain queued issues when no active jobs exist
- **Daemon reliability** — Single-worker mode, stagger spawns, sort tiebreaker
- **Template name corruption** in daemon spawning
- **Progress.md** written on all loop exit paths
- **Restart lifecycle** and fast-test double-run elimination

---

## [1.9.0] — 2026-02-12

**Progress-Based Health Monitoring.**

### Added

- **Intelligent progress monitoring** — Pipeline health scoring based on iteration progress, not just timeouts

### Fixed

- **Production reliability hardening** — Locking, timeouts, cleanup, state safety

---

## [1.8.1] — 2026-02-11

**Daemon Stability.**

### Fixed

- **Daemon signal handling** — Trap SIGPIPE, log ERR to file, guard sleep
- **Daemon poll loop** — Error-guard to prevent crash on transient failures
- **Daemon state** — Eliminate eval injection, enforce Bash 3.2 compatibility
- **PID/issue_num validation** from JSON before use in daemon reaper
- **`local` outside function** in `sw-status.sh`

---

## [1.8.0] — 2026-02-11

**Intelligence Layer & Deep GitHub Integration.**

Major capability expansion: full intelligence layer with adaptive thresholds, deep GitHub API integration (GraphQL, Checks, Deployments), agent heartbeat/checkpoint system, self-healing CI, and cross-platform compatibility.

### Added

- **Intelligence layer** — Adaptive thresholds, feedback loops, semantic detection
- **GitHub GraphQL client** — Cached queries for file churn, blame, contributors, similar issues
- **GitHub Checks API** — Native Check Runs per pipeline stage
- **GitHub Deployments API** — Environment tracking with rollback support
- **Agent heartbeat/checkpoint** — Persistent agent health monitoring
- **Multi-machine workers** — Distributed execution across remote machines
- **Self-healing CI** — Auto-retry with strategy engine and health dashboard
- **AI triage gate** — Intelligent issue labeling in CI pipeline
- **Cross-platform compat library** — `scripts/lib/compat.sh` for macOS + Linux
- **Auto-launch Claude Code** with team prompt in session command
- **Compound quality stage** in pipeline
- **24/7 sweep cron** for missed pipeline triggers

### Fixed

- **Pipeline loop exits** from stdin consumption in while-read
- **Daemon hardening** — Rate-limit circuit breaker, locked state ops, stale cleanup
- **Daemon resilience** — State locking, FD leaks, zombie recovery, capacity bounds
- **Daemon crash** on tmux attach and orphaned child processes
- **PR quality gate** and title generation
- **Bash 3.2 compatibility** — Install hardening, doctor enhancements
- **Pipeline timeout** simplified — Watchdog handles stuck detection

---

## [1.7.0] — 2026-02-08

**Superhuman Scale.**

Scale from 2 concurrent pipelines to 8+ with resource-aware auto-scaling, cross-repo fleet worker distribution, and parallel-safe worktree isolation. First npm publish.

### Added

- **Auto-scaling daemon**: `daemon_auto_scale()` dynamically adjusts worker count based on CPU cores (75% cap), available memory, remaining budget, and queue depth — cross-platform (macOS + Linux)
- **Fleet worker pool**: `worker_pool` config in fleet enables demand-based distribution of a total worker budget across repos, with a background rebalancer loop
- **Pipeline `--worktree` flag**: `shipwright pipeline start --issue 42 --worktree` runs in an isolated git worktree for parallel-safe ad-hoc pipelines
- **Cost `remaining-budget`**: `shipwright cost remaining-budget` returns remaining daily budget as a number (consumed by auto-scaler)
- **Fleet config reload**: daemons pick up fleet-assigned worker counts via `daemon_reload_config()` and a flag file signal
- **CLAUDE.md auto-install**: npm postinstall now installs Shipwright agent instructions to `~/.claude/CLAUDE.md` (idempotent — appends if file exists, creates if not)

### Fixed

- **npm symlink resolution**: CLI router now follows symlinks so all 19 subcommands resolve correctly when installed via `npm install -g`
- **Version sync**: All 12 scripts + package.json aligned at v1.7.0
- **npm package hygiene**: Excluded test scripts and dev tools from published package — 72 files, 192KB (down from 82 files, 229KB)
- **vm_stat parsing** (macOS): Fixed page size extraction from `(page size of 16384 bytes)` format, added inactive + purgeable pages for accurate available memory
- **Bash 3.2 compatibility**: Replaced associative arrays (`local -A`) in fleet rebalancer with indexed arrays for macOS default bash
- **Fleet/auto-scale race condition**: Introduced `FLEET_MAX_PARALLEL` ceiling so auto-scale respects fleet-assigned worker limits
- **Worker over-allocation**: Added budget correction loop in fleet rebalancer when rounding exceeds total
- **Trap chaining**: Pipeline worktree cleanup now chains with existing exit handler instead of overwriting it
- **Worktree cleanup**: Stores `ORIGINAL_REPO_DIR` before `cd` instead of fragile `git worktree list` parsing
- **Numeric validation**: Added regex validation for load average, queue depth, budget values, and cost calculations
- **Poll loop ordering**: Moved `POLL_CYCLE_COUNT` increment before all modulo checks for consistent timing
- **Rebalancer shutdown**: Added flag file for clean loop exit when fleet stops

### Changed

- `npm test` now runs all 6 test suites (pipeline, daemon, prep, fleet, fix, memory) — 90 tests total
- CLAUDE.md.shipwright template updated with auto-scale config, fleet worker pool, `--worktree` usage, daemon config reference table

---

## [1.6.0] — 2026-02-07

**The Shipwright Launch.**

The project formerly known as `shipwright` is now **Shipwright** — a proper CLI with professional distribution, shell completions, a documentation website, and CI/CD.

### Added

- **Brand identity**: Shipwright naming with `shipwright` and `sw` as CLI entry points
- **npm distribution**: `npm install -g shipwright-cli` — bash scripts distributed via npm, zero Node dependencies at runtime
- **curl installer**: `curl -fsSL https://raw.githubusercontent.com/sethdford/shipwright/main/scripts/install-remote.sh | sh` — self-contained, detects OS and architecture
- **Homebrew tap**: `brew install sethdford/shipwright/shipwright`
- **Shell completions**: Full tab completion for bash, zsh, and fish — all commands, subcommands, and flags
- **Completion installer**: `scripts/install-completions.sh` auto-detects shell and installs to the right location
- **Documentation website**: Astro Starlight site at sethdford.github.io/shipwright — landing page, CLI reference, guides for pipeline/daemon/prep/loop, template catalog, configuration, troubleshooting, FAQ
- **CI/CD pipeline**: GitHub Actions for test matrix (macOS + Ubuntu), release automation (tarballs + npm + Homebrew), and website deployment
- **Release tooling**: `scripts/build-release.sh` builds platform tarballs with SHA256 checksums; `scripts/update-version.sh` bumps version across all scripts atomically
- **Postinstall setup**: `scripts/postinstall.mjs` copies templates to `~/.shipwright/` and migrates legacy `~/.claude-teams/` non-destructively

### Changed

- CLI help and version output now show "Shipwright" branding with alias hints
- `install.sh` rebranded — creates `shipwright` and `sw` symlinks, copies templates to `~/.shipwright/`
- README rewritten with multi-method install section, updated CLI examples, and website link

---

## [1.5.1] — 2026-02-07

### Added

- **Automatic pane reaper**: `shipwright reaper` watches for exited agent processes and cleans up their tmux panes automatically — no more dead panes cluttering your workspace

---

## [1.5.0] — 2026-02-06

**The Autonomous Development Lifecycle.**

This release turns Shipwright from a team session manager into a full autonomous development system. Point it at a GitHub issue and walk away.

### Added

- **Autonomous daemon** (`shipwright daemon`): Watches a GitHub repo for labeled issues, spawns delivery pipelines automatically, manages concurrent work, and reports results back to the issue thread
- **Repo preparation** (`shipwright prep`): Analyzes any repository and generates agent-optimized `.claude/` configurations — CLAUDE.md, settings.json, hooks, and test commands. Supports `--with-claude` for deep AI-assisted analysis
- **Compound quality stage**: Pipeline build stage now runs iterative quality cycles — lint, typecheck, test, and self-heal in a loop until the code is clean or the retry budget is exhausted
- **DORA metrics dashboard** (`shipwright daemon metrics`): Deployment frequency, cycle time, change failure rate, and mean time to recovery — graded against Google's Elite/High/Medium/Low thresholds
- **DX metrics**: First-pass quality rate, self-heal efficiency, and autonomy score alongside DORA
- **Event logging**: All pipeline and daemon events written to `~/.shipwright/events.jsonl` for metrics, auditing, and debugging
- **Autonomous pipeline template**: New `autonomous.json` pipeline — all stages auto-approved, designed for daemon-driven delivery
- **Daemon test suite**: `shipwright daemon test` — comprehensive validation of daemon startup, polling, pipeline spawning, and metrics calculation
- **Prep test suite**: `shipwright prep test` — validation of repo analysis, config generation, and Claude integration

---

## [1.4.0] — 2026-02-04

**Full SDLC Template Catalog.**

### Added

- 8 new team templates covering the complete software development and product lifecycle:
  - **security-audit** (3 agents): Code analysis, dependency scanning, config review
  - **testing** (3 agents): Unit, integration, and end-to-end test generation
  - **migration** (3 agents): Schema, adapter, and rollback coordination
  - **bug-fix** (3 agents): Reproduce, fix, verify workflow
  - **architecture** (2 agents): Research and spec writing
  - **exploration** (2 agents): Codebase deep-dive and synthesis
  - **devops** (2 agents): CI/CD pipeline and infrastructure
  - **documentation** (2 agents): API reference and guides

### Changed

- Template count: 4 to 12 — covers build, quality, maintenance, planning, and operations phases
- Demo GIFs re-recorded for the expanded template catalog
- GIFs hosted on vhs.charm.sh to keep the repo lean

---

## [1.3.0] — 2026-02-03

### Added

- **`shipwright init`**: One-command tmux setup — installs config, overlay, and theme with zero prompts
- **Continuous agent loop** (`shipwright loop`): Run Claude autonomously with test verification, audit modes (self-audit and separate auditor), quality gates, and definition-of-done checklists
- **Layout presets**: Keybindings for main-horizontal (leader 65% left), main-vertical (leader 60% top), and tiled layouts
- **jq dependency**: Required for JSON template parsing (replaces python3)

### Fixed

- Pane display rendering issues with agent name headers
- Replaced python3 dependency with jq for broader compatibility

---

## [1.2.0] — 2026-02-02

### Added

- **Continuous agent loop** (`shipwright loop`): Autonomous multi-iteration development with test gates
- **Git worktree management** (`shipwright worktree`): Isolate agent work in separate worktrees to prevent conflicts

---

## [1.1.0] — 2026-02-01

### Added

- **`shipwright upgrade`**: Check for updates from the repo, diff changes, apply selectively
- **`shipwright doctor`**: Validate tmux version, jq, overlay hooks, color config, orphaned sessions
- **`shipwright logs`**: View and search agent pane output with `--follow` mode
- **`shipwright ps`**: Show running agent processes with status indicators
- **`shipwright templates`**: Browse and inspect team composition templates
- **Upgrade manifest**: `~/.shipwright/manifest.json` tracks installed files for safe upgrades

### Fixed

- tmux conditional syntax for version-dependent features

---

## [1.0.0] — 2026-01-31

**Initial release.**

### Added

- Premium dark tmux theme with cyan accent (`#00d4ff`), agent-aware pane borders
- `shipwright session` for creating team windows from templates
- `shipwright status` dashboard for monitoring active teams
- `shipwright cleanup` for orphaned session management
- 4 team templates: feature-dev, full-stack, code-review, refactor
- Quality gate hooks: teammate-idle (typecheck), task-completed (lint + test)
- Notification hooks: desktop alerts on agent idle
- Pre-compact hook: save git context before compaction
- Claude Code settings template with agent teams, auto-compact, subagent model
- Interactive installer with dry-run mode
- vim-style pane navigation and copy mode
- TPM plugin manager integration

---

[2.1.0]: https://github.com/sethdford/shipwright/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/sethdford/shipwright/compare/v1.10.0...v2.0.0
[1.12.0]: https://github.com/sethdford/shipwright/compare/v1.10.0...v1.12.0
[1.10.0]: https://github.com/sethdford/shipwright/compare/v1.9.0...v1.10.0
[1.9.0]: https://github.com/sethdford/shipwright/compare/v1.8.1...v1.9.0
[1.8.1]: https://github.com/sethdford/shipwright/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/sethdford/shipwright/compare/v1.7.0...v1.8.0
[1.7.0]: https://github.com/sethdford/shipwright/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/sethdford/shipwright/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/sethdford/shipwright/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/sethdford/shipwright/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/sethdford/shipwright/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/sethdford/shipwright/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/sethdford/shipwright/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/sethdford/shipwright/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/sethdford/shipwright/releases/tag/v1.0.0
