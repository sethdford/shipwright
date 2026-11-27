# Shipwright Documentation

Navigation hub for all Shipwright docs. Start here or jump to a section.

---

## Root Documentation

| Doc                                          | Purpose                                             |
| -------------------------------------------- | --------------------------------------------------- |
| [../README.md](../README.md)                 | Project overview, quick start, features             |
| [../STRATEGY.md](../STRATEGY.md)             | Vision, priorities, technical principles            |
| [../CHANGELOG.md](../CHANGELOG.md)           | Version history                                     |
| [UPGRADING.md](UPGRADING.md)                 | What to change when upgrading (3.x to 4.0)          |
| [reference/legacy-guide.md](reference/legacy-guide.md) | 100+ commands, architecture, development guidelines |

---

## Architecture, Decisions and Safety

| Doc | Purpose |
| --- | --- |
| [architecture.md](architecture.md) | Bounded contexts, layers, fitness rules, durability |
| [adr/README.md](adr/README.md) | Index of architecture decisions (ADR-0001 to 0016) and how they fit together |
| [reference/switches.md](reference/switches.md) | Every pipeline switch and ablation arm, with defaults and where it is read |
| [reference/cli.md](reference/cli.md) | Generated help for the TypeScript commands (`bun run docs:gen`) |
| [reference/dependency-graph.md](reference/dependency-graph.md) | Generated import graph |
| [benchmark/README.md](benchmark/README.md) | Running and publishing the head-to-head benchmark |
| [safety-runbook.md](safety-runbook.md) | Operator runbook for the dispatch gates (ADR-0007) |
| [dashboard-exposure.md](dashboard-exposure.md) | Exposing the dashboard: auth, fleet token, roles |
| [../.shipwright/lessons/README.md](../.shipwright/lessons/README.md) | Repository lesson format and the self-improvement loop |

### Proof, verification and safety at a glance

| Feature | Command | Decision | User guide |
| --- | --- | --- | --- |
| Delivery scorecard, eval ratchet | `scorecard`, `eval` | ADR-0009 | [Proof Engine](https://sethdford.github.io/shipwright/guides/proof/) |
| Head-to-head benchmark | `bench` | [ADR-0013](adr/0013-head-to-head-benchmark.md) | [Proof Engine](https://sethdford.github.io/shipwright/guides/proof/#head-to-head-benchmark) |
| Merge verifier | `verify` | [ADR-0012](adr/0012-learned-merge-verifier.md) | [Verification](https://sethdford.github.io/shipwright/guides/verification/#3-merge-verifier) |
| Tournament mode | `tournament` | (PR #8744) | [Verification](https://sethdford.github.io/shipwright/guides/verification/#2-tournament-builds) |
| Spec-first acceptance tests | `acceptance` | [ADR-0015](adr/0015-spec-first-acceptance-tests.md) | [Verification](https://sethdford.github.io/shipwright/guides/verification/#1-spec-first-acceptance-tests) |
| Compute router | `route` | [ADR-0014](adr/0014-adaptive-compute-router.md) | [Intelligence](https://sethdford.github.io/shipwright/guides/intelligence/#adaptive-compute-router) |
| Repository world model | `repomodel` | [ADR-0016](adr/0016-repository-world-model.md) | [Intelligence](https://sethdford.github.io/shipwright/guides/intelligence/#repository-world-model) |
| Lessons and governance | `governance` | [ADR-0010](adr/0010-repository-lessons-and-governance-pack.md) | [Governance](https://sethdford.github.io/shipwright/guides/governance/) |
| Patch handoff, untrusted input, dashboard roles | (pipeline, dashboard) | [ADR-0011](adr/0011-patch-handoff-trust-boundary.md) | [Trust Boundary](https://sethdford.github.io/shipwright/guides/trust-boundary/) |

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
| [../.claude/agents/](../.claude/agents/)                             | Subagents (reviewer, verifier, porter, doc-fleet-agent)                 |

---

## See Also

- [../CHANGELOG.md](../CHANGELOG.md) — Version history and release notes
- **Release automation** — Prefer CLI: `shipwright version bump <x.y.z>`, `shipwright version check`, `shipwright release build`. Scripts: `scripts/update-version.sh`, `scripts/check-version-consistency.sh`, `scripts/build-release.sh`. Website footer reads version from repo `package.json` at build time.
- [demo/README.md](../demo/README.md) — Demo app for pipeline testing
- [claude-code/CLAUDE.md.shipwright](../claude-code/CLAUDE.md.shipwright) — Downstream repo template
- [.github/pull_request_template.md](../.github/pull_request_template.md) — PR checklist
