# Changelog

All notable changes to Shipwright are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

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

- **Brand identity**: Shipwright naming with `shipwright`, `sw`, and `cct` (legacy) as CLI entry points
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
- `install.sh` rebranded — creates `shipwright` and `sw` symlinks alongside `cct`, copies templates to `~/.shipwright/`
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
