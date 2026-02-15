# Shipwright Strategy

> Living document. Read by the strategic intelligence agent to guide autonomous product development.
> Last human review: 2026-02-14

## Vision

Make autonomous software delivery accessible to every developer. Shipwright is the definitive orchestration layer for Claude Code agent teams — turning GitHub issues into shipped, tested, reviewed pull requests without human intervention.

## Mission

Build a system that is **always improving itself** — where every pipeline run generates data that makes the next run smarter, faster, and more reliable.

## Current State (What We Have)

- **Core pipeline**: 12-stage delivery (intake → monitor), template-based, CI-native
- **Daemon**: Autonomous issue processing with auto-scaling, retry intelligence, failure classification
- **Fleet**: Multi-repo orchestration with worker pool distribution
- **Intelligence**: Predictive risk scoring, self-optimization, regression detection, pipeline vitals
- **CI parity**: Full GitHub Actions support — dispatch, patrol, sweep, retry, optimization
- **Dashboard**: Real-time web UI with WebSocket streaming
- **Memory**: Persistent failure patterns, cross-pipeline learning
- **Cost intelligence**: Budget enforcement, model routing, usage tracking
- **Observability**: DORA metrics, event bus, OpenTelemetry, GitHub Checks integration

## Strategic Priorities

### P0: Reliability & Success Rate

The most important metric is pipeline success rate. Every failure that could have been prevented is a wasted cycle.

- Improve failure classification accuracy
- Better error feedback loops between build iterations
- Smarter retry strategies based on failure patterns
- Reduce context exhaustion failures (session restart improvements)
- Pre-build validation (catch issues before burning iterations)

### P1: Developer Experience

Shipwright should be trivial to set up and delightful to use.

- One-command setup that works on macOS and Linux
- Clear, actionable error messages
- Better onboarding documentation
- Interactive dashboard improvements
- Template recommendations based on project type

### P2: Intelligence & Learning

The system should get measurably smarter over time.

- Predictive issue complexity scoring from historical data
- Adaptive iteration counts based on past outcomes
- Cross-repo learning (fleet-wide pattern sharing)
- Architecture-aware pipeline composition
- Automatic template evolution based on success rates

### P3: Cost Efficiency

Maximize value per dollar spent on AI compute.

- Intelligent model routing (use Haiku for simple tasks, Opus for complex)
- Early termination when build is clearly failing
- Parallel stage execution where safe
- Caching of repeated analysis (intelligence cache improvements)
- Budget-aware template selection

### P4: Observability & Metrics

You can't improve what you can't measure.

- End-to-end traceability (issue → commit → PR → deploy)
- Pipeline health scoring trends over time
- Anomaly detection with actionable alerts
- DORA metrics benchmarking against industry standards
- Cost-per-issue tracking and optimization

### P5: Community & Growth

Open source growth through demonstrated value.

- Public showcase of autonomous delivery stats
- Contributor-friendly issue templates and docs
- Example configurations for popular project types
- Plugin/extension architecture for custom stages

## Technical Principles

1. **Bash-first, Bash 3.2 compatible** — runs everywhere macOS ships
2. **Atomic operations** — tmp file + mv, never partial writes
3. **Graceful degradation** — intelligence features are advisory, never blocking
4. **Data-driven decisions** — every optimization backed by metrics
5. **Self-healing** — retry with escalation, not just retry
6. **Cost-conscious** — always consider the budget impact
7. **Test everything** — every script gets a test suite

## What We're NOT Building

- GUI desktop application (CLI-first, web dashboard for monitoring)
- Non-Claude AI integration (Claude Code is the execution engine)
- Enterprise SaaS platform (open source, self-hosted)
- General CI/CD replacement (orchestration layer, not a build system)

## Success Metrics

| Metric                                  | Current | Target  |
| --------------------------------------- | ------- | ------- |
| Pipeline success rate                   | ~77%    | >85%    |
| Avg pipeline duration                   | ~90 min | <60 min |
| Setup time (new repo)                   | ~30 min | <5 min  |
| Test coverage (scripts with tests)      | ~80%    | >90%    |
| Cost per successful pipeline            | ~$5-10  | <$5     |
| Mean time to recovery (failed pipeline) | ~2h     | <30 min |

## Feedback Signals

The strategic agent should consider these data sources:

- **Pipeline events** (`events.jsonl`): success/failure rates, stage durations, error types
- **DORA metrics**: lead time, deployment frequency, change failure rate, MTTR
- **Open issues**: what's in-flight, what's stuck, what's failing repeatedly
- **Memory patterns**: recurring failures, successful fixes, codebase conventions
- **Test results**: which scripts are tested, coverage gaps
- **Cost data**: spending trends, cost per pipeline, budget utilization
