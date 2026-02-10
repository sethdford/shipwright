# Shipwright

The Autonomous Delivery Platform — from labeled issue to merged PR.

[![Tests](https://github.com/sethdford/shipwright/actions/workflows/test.yml/badge.svg)](https://github.com/sethdford/shipwright/actions/workflows/test.yml) ![MIT License](https://img.shields.io/badge/license-MIT-green?style=flat-square) ![v1.7.1](https://img.shields.io/badge/version-1.7.1-00d4ff?style=flat-square)

## Shipwright Builds Itself

This repo uses Shipwright to process its own issues. Label a GitHub issue with `shipwright` and the autonomous pipeline runs: semantic triage → plan → design → build → test → review → quality gates → PR. See [recent pipeline runs](../../actions/workflows/shipwright-pipeline.yml).

Try it yourself — create an issue using the "Let Shipwright Build This" template.

## Install

**curl** (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/sethdford/shipwright/main/scripts/install-remote.sh | bash
```

**From source**

```bash
git clone https://github.com/sethdford/shipwright.git
cd shipwright && ./install.sh
```

## What You Get

- 12-stage delivery pipeline (intake to monitoring)
- Autonomous daemon that watches GitHub for labeled issues
- Fleet operations across multiple repositories
- 24 team templates for agent coordination
- Intelligence layer: semantic triage, pipeline composition, predictive risk, adversarial review, architecture enforcement
- Self-healing builds with persistent memory
- DORA metrics and cost intelligence
- Real-time web dashboard

## Quick Start

```bash
shipwright init                           # One-command tmux setup
shipwright pipeline start --issue 42      # Full delivery pipeline
shipwright daemon start                   # Watch GitHub for issues
shipwright session my-feature -t feature-dev  # 3-agent team
shipwright loop "Build auth" --test-cmd "npm test"  # Continuous loop
```

## Pipeline

12-stage autonomous delivery:

```
intake → plan → design → build → test → review → compound_quality → pr → merge → deploy → validate → monitor
```

Stages are configurable. Quality gates can auto-proceed or pause for approval. Choose from 8 templates: `fast` (quick fixes), `standard` (feature work), `hotfix`, `autonomous` (daemon-driven), `enterprise` (maximum safety), `cost-aware` (budget limits), `full` (all stages), or `deployed` (full deploy + monitoring).

When tests fail, the pipeline automatically re-enters the build loop with error context — self-healing like a human developer reading failures and fixing them.

## Intelligence Layer

7 intelligence modules behind feature flags, all degrading gracefully if disabled. Enable in `.claude/daemon-config.json` under `intelligence`:

- **Intelligence Core** — Semantic issue analysis, AI-powered memory search, intelligent model routing by stage complexity
- **Pipeline Composer** — Generates custom pipeline configurations from codebase analysis (file change frequency, test coverage, layer dependencies)
- **Self-Optimization** — Reads DORA metrics (lead time, deployment frequency, change failure rate, MTTR) and auto-tunes daemon config
- **Predictive Analytics** — Risk scoring of incoming issues, anomaly detection in pipeline metrics, AI patrol summaries
- **Adversarial Review** — Hostile code review pass looking for security flaws, edge cases, and failure modes
- **Developer Simulation** — 3-persona review (security, performance, maintainability) before PR
- **Architecture Enforcement** — Living architectural model with violation detection and dependency direction rules

All modules are optional. The pipeline degrades gracefully if any are disabled.

## Prerequisites

| Requirement         | Version                           | Notes                                                                     |
| ------------------- | --------------------------------- | ------------------------------------------------------------------------- |
| **tmux**            | 3.2+                              | `brew install tmux` on macOS                                              |
| **jq**              | any                               | `brew install jq` — JSON parsing                                          |
| **Claude Code CLI** | latest                            | `npm install -g @anthropic-ai/claude-code`                                |
| **Node.js**         | 20+                               | For hooks                                                                 |
| **Git**             | any                               | For installation                                                          |
| **Terminal**        | iTerm2, Alacritty, Kitty, WezTerm | Real terminal emulators only (not VS Code integrated terminal or Ghostty) |

## Documentation

Full docs at [sethdford.github.io/shipwright](https://sethdford.github.io/shipwright)

## Commands

| Command                                        | Purpose                                |
| ---------------------------------------------- | -------------------------------------- |
| `shipwright init`                              | One-command tmux setup                 |
| `shipwright pipeline start --issue 42`         | Full delivery pipeline for issue       |
| `shipwright pipeline start --goal "..."`       | Pipeline from goal description         |
| `shipwright daemon start`                      | Watch GitHub for labeled issues        |
| `shipwright daemon start --detach`             | Start daemon in background             |
| `shipwright daemon metrics`                    | DORA metrics dashboard                 |
| `shipwright fleet start`                       | Multi-repo orchestration               |
| `shipwright fix "..." --repos ~/a,~/b`         | Bulk fix across repos                  |
| `shipwright loop "..." --test-cmd "npm test"`  | Continuous autonomous loop             |
| `shipwright session my-feature -t feature-dev` | 3-agent team session                   |
| `shipwright memory show`                       | View persistent memory                 |
| `shipwright cost show`                         | 7-day cost summary                     |
| `shipwright prep`                              | Repo preparation and config generation |
| `shipwright doctor`                            | Validate setup and diagnose issues     |

## Contributing

Create an issue using the "Let Shipwright Build This" template and label it `shipwright`. The autonomous pipeline will triage, build, and create a PR.

For manual development: fork, branch, then run `npm test` (278 tests across 17 suites).

## License

MIT — Seth Ford, 2026.
