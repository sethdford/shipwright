# Architecture decision records

Each record states one decision, why it was made, and what it costs. Add one with the
`write-adr` skill when you choose between approaches that a later contributor would otherwise
re-debate. Records are numbered in the order they were agreed, and a number is never reused.

**Agents read these.** The governance brief (ADR-0010) puts the Decision section of every ADR
in force into the build prompt, read from the base commit. `proposed`, `superseded`,
`deprecated`, `rejected` and `retired` records are left out; anything else, including a record
with no status, is in force. Changing a status therefore changes
what agents are told, so do it in its own reviewed PR.

## Index

| # | Decision | Status | Area |
|---|---|---|---|
| [0001](0001-typescript-on-bun.md) | TypeScript on Bun | accepted | Platform |
| [0002](0002-modular-monolith.md) | Modular monolith with Clean Architecture | accepted | Platform |
| [0003](0003-claude-agent-sdk.md) | Claude Agent SDK behind one port | accepted | Agents |
| [0004](0004-strangler-with-parity-oracle.md) | Strangler migration with bash suites as the parity oracle | accepted | Migration |
| [0005](0005-durability-contract-and-deployment-modes.md) | Durability contract and three deployment modes | accepted | Platform |
| 0006 | Not used | n/a | |
| [0007](0007-safety-controls.md) | Safety controls gate every dispatch | accepted | Safety |
| [0008](0008-fitness-functions-everywhere.md) | Fitness functions everywhere, with ratchets for legacy code | accepted | Quality |
| [0009](0009-closed-loop-learning.md) | Closed-loop learning: measured, gated, and outside the agent's reach | proposed | Learning |
| [0010](0010-repository-lessons-and-governance-pack.md) | Repository lessons and a governance pack, read from the base commit (amendment 1: the self-improvement loop) | accepted | Governance |
| [0011](0011-patch-handoff-trust-boundary.md) | Agent output crosses into the trusted pipeline only as a patch | proposed | Safety |
| [0012](0012-learned-merge-verifier.md) | A learned merge verifier, gated by its own calibration | accepted | Quality |
| [0013](0013-head-to-head-benchmark.md) | Head-to-head benchmark: Shipwright against bare Claude Code on hidden tests | proposed | Quality |
| [0014](0014-adaptive-compute-router.md) | Adaptive compute router: route by difficulty, log every decision, apply only by opt-in | accepted | Intelligence |
| [0015](0015-spec-first-acceptance-tests.md) | Spec-first acceptance tests: proven red, locked, and the build gate | accepted | Planning |
| [0016](0016-repository-world-model.md) | A repository world model that agents query through tools | accepted | Intelligence |

## How the records fit together

**Foundations (0001 to 0005, 0008).** Shipwright is a TypeScript modular monolith on Bun that
replaces the bash scripts one command at a time. Each port must pass the old command's bash
suite first (0004). Run state goes through durability ports so the same code runs on one laptop
or many machines (0005). Architecture rules are executable and ratcheted, never suppressed (0008).

**Safety (0007, 0011).** Every dispatch passes fail-closed gates: a circuit breaker, a retry cap,
a daily budget and intake checks (0007). Agents never hold GitHub credentials, and the build
agent's work reaches the trusted checkout only as a patch that is judged as data first (0011).

**Learning without self-deception (0009, 0010).** Every adaptive decision is logged with its
inputs. Difficulty comes from history, never from the model's own estimate. Adaptation may only
tighten limits, and a policy change ships only when it wins a paired ratchet on the same cases
(0009). Lessons are reviewed text in the repository, given to agents from the base commit. The
self-improvement loop drafts and trials them, but a person merges every status change (0010).

**Proof (0012, 0013).** The merge verifier predicts whether a change will merge and stay merged,
and may block on that prediction only after it is calibrated on the factory's own PRs (0012).
The benchmark compares Shipwright with bare Claude Code on hidden tests, with paired statistics
and a hard budget (0013). Both feed the eval ratchet from `shipwright eval`.

**Doing the work better (0014, 0015, 0016).** The compute router sizes each run by difficulty and
runs in shadow mode until the ratchet supports applying it (0014). Acceptance tests are written
before the code, proven to fail, locked outside the agent's reach, and gate the build (0015).
Agents query a persistent model of the repository instead of grepping from scratch (0016).

## Format

    # NNNN. Title

    Status: proposed | accepted | superseded by NNNN | deprecated · Date: YYYY-MM-DD

    ## Context
    ## Decision
    ## Consequences

Keep the Decision section self-contained: it is the part the governance brief quotes.
