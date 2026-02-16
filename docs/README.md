# Shipwright Documentation

Navigation hub for all Shipwright docs. Start here or jump to a section.

---

## Root Documentation

| Doc                                          | Purpose                                             |
| -------------------------------------------- | --------------------------------------------------- |
| [../README.md](../README.md)                 | Project overview, quick start, features             |
| [../STRATEGY.md](../STRATEGY.md)             | Vision, priorities, technical principles            |
| [../CHANGELOG.md](../CHANGELOG.md)           | Version history                                     |
| [../.claude/CLAUDE.md](../.claude/CLAUDE.md) | 100+ commands, architecture, development guidelines |

---

## docs/ Sections

### Strategy & GTM

| Doc                                                                  | Purpose                                               |
| -------------------------------------------------------------------- | ----------------------------------------------------- |
| [strategy/README.md](strategy/README.md)                             | Strategic docs index — market research, brand, GTM    |
| [strategy/01-market-research.md](strategy/01-market-research.md)     | Market size, competitive landscape, customer segments |
| [strategy/02-mission-and-brand.md](strategy/02-mission-and-brand.md) | Mission, vision, brand positioning, messaging         |
| [strategy/03-gtm-and-roadmap.md](strategy/03-gtm-and-roadmap.md)     | Go-to-market, 4-phase roadmap, success metrics        |

### Team Patterns (Wave-Style)

| Doc                                                                      | Purpose                                       |
| ------------------------------------------------------------------------ | --------------------------------------------- |
| [patterns/README.md](patterns/README.md)                                 | Wave patterns index — parallel agent work     |
| [patterns/feature-implementation.md](patterns/feature-implementation.md) | Multi-component feature builds                |
| [patterns/research-exploration.md](patterns/research-exploration.md)     | Codebase exploration                          |
| [patterns/test-generation.md](patterns/test-generation.md)               | Test coverage campaigns                       |
| [patterns/refactoring.md](patterns/refactoring.md)                       | Large-scale transformations                   |
| [patterns/bug-hunt.md](patterns/bug-hunt.md)                             | Tracking complex bugs                         |
| [patterns/audit-loop.md](patterns/audit-loop.md)                         | Self-reflection and quality gates in the loop |

### tmux Research

| Doc                                                                                              | Purpose                                   |
| ------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| [tmux-research/TMUX-RESEARCH-INDEX.md](tmux-research/TMUX-RESEARCH-INDEX.md)                     | Index and reading guide                   |
| [tmux-research/TMUX-BEST-PRACTICES-2025-2026.md](tmux-research/TMUX-BEST-PRACTICES-2025-2026.md) | Configuration bible                       |
| [tmux-research/TMUX-ARCHITECTURE.md](tmux-research/TMUX-ARCHITECTURE.md)                         | Visual architecture, integration patterns |
| [tmux-research/TMUX-QUICK-REFERENCE.md](tmux-research/TMUX-QUICK-REFERENCE.md)                   | Fast lookup, keybindings                  |
| [tmux-research/TMUX-AUDIT.md](tmux-research/TMUX-AUDIT.md)                                       | Shipwright tmux config audit report       |

### Platform & AGI

| Doc                                                  | Purpose                                     |
| ---------------------------------------------------- | ------------------------------------------- |
| [AGI-PLATFORM-PLAN.md](AGI-PLATFORM-PLAN.md)         | Phased refactor for autonomous product dev  |
| [AGI-WHATS-NEXT.md](AGI-WHATS-NEXT.md)               | Gaps, not-yet-implemented, E2E audit status |
| [PLATFORM-TODO-BACKLOG.md](PLATFORM-TODO-BACKLOG.md) | TODO/FIXME/HACK triage backlog              |
| [config-policy.md](config-policy.md)                 | Policy config schema and usage              |

### Reference & Troubleshooting

| Doc                                                            | Purpose                                             |
| -------------------------------------------------------------- | --------------------------------------------------- |
| [TIPS.md](TIPS.md)                                             | Power user tips, team patterns                      |
| [KNOWN-ISSUES.md](KNOWN-ISSUES.md)                             | Tracked bugs and workarounds                        |
| [definition-of-done.example.md](definition-of-done.example.md) | Template for `shipwright loop --definition-of-done` |

---

## .claude/ Agent Definitions

| File                                                                 | Purpose                                                                 |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| [../.claude/DEFINITION-OF-DONE.md](../.claude/DEFINITION-OF-DONE.md) | Pipeline completion checklist                                           |
| [../.claude/agents/](../.claude/agents/)                             | Role definitions (pipeline-agent, code-reviewer, test-specialist, etc.) |

---

## See Also

- [../CHANGELOG.md](../CHANGELOG.md) — Version history and release notes
- **Release automation** — Prefer CLI: `shipwright version bump <x.y.z>`, `shipwright version check`, `shipwright release build`. Scripts: `scripts/update-version.sh`, `scripts/check-version-consistency.sh`, `scripts/build-release.sh`. Website footer reads version from repo `package.json` at build time.
- [demo/README.md](../demo/README.md) — Demo app for pipeline testing
- [claude-code/CLAUDE.md.shipwright](../claude-code/CLAUDE.md.shipwright) — Downstream repo template
- [.github/pull_request_template.md](../.github/pull_request_template.md) — PR checklist
