# Changelog

All notable changes to Shipwright are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **Event logging**: All pipeline and daemon events written to `~/.claude-teams/events.jsonl` for metrics, auditing, and debugging
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
- **Upgrade manifest**: `~/.claude-teams/manifest.json` tracks installed files for safe upgrades

### Fixed

- tmux conditional syntax for version-dependent features

---

## [1.0.0] — 2026-01-31

**Initial release.**

### Added

- Premium dark tmux theme with cyan accent (`#00d4ff`), agent-aware pane borders
- `cct session` for creating team windows from templates
- `cct status` dashboard for monitoring active teams
- `cct cleanup` for orphaned session management
- 4 team templates: feature-dev, full-stack, code-review, refactor
- Quality gate hooks: teammate-idle (typecheck), task-completed (lint + test)
- Notification hooks: desktop alerts on agent idle
- Pre-compact hook: save git context before compaction
- Claude Code settings template with agent teams, auto-compact, subagent model
- Interactive installer with dry-run mode
- vim-style pane navigation and copy mode
- TPM plugin manager integration

---

[1.6.0]: https://github.com/sethdford/shipwright/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/sethdford/shipwright/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/sethdford/shipwright/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/sethdford/shipwright/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/sethdford/shipwright/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/sethdford/shipwright/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/sethdford/shipwright/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/sethdford/shipwright/releases/tag/v1.0.0
