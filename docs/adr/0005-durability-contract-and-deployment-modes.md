# 0005. Durability contract and three deployment modes

Status: accepted · Date: 2026-10-14

## Context
Shipwright must run in three modes from one codebase: M1 local with zero ops, M2 a server daemon,
M3 several machines coordinating.

Today's coordination is ad hoc. `claimed:<machine>` labels are not atomic and consume GitHub's rate
limit. SSH rebalance and event tail, `machine-health.json` failover, and file heartbeats and
checkpoints fill the gaps. Nothing stops a laptop that wakes after a takeover from pushing or
commenting twice.

The engines don't fit yet (2027 strategy research, durability note §0):
- Temporal and Restate each need a separate server, which breaks M1.
- Temporal's Bun workers are experimental.
- Restate pushes to workers, which fails behind NAT.
- DBOS has no SQLite or Bun support yet.

## Decision
Own a small durability contract: four ports in `src/shared/kernel/durability.ts`.
- `WorkQueue`: atomic claim with a lease, heartbeat and complete; dedupe key; `notBefore`, which is
  also the timer wake; per-pool `maxActive` checked inside the claim.
- `RunJournal`: append-only and fenced.
- `Signals`: durable approvals, cancel and pause.
- `SideEffects`: a reconcile-then-act ledger keyed by `IdempotencyKey`.

Every claim increments the item's lease epoch, its fence token. Every journal append and every
external side effect checks the fence; a stale fence fails.

Each work item belongs to one run, and a run has at most one unfinished item. The journal derives
the run from the fence, so a lease can append only to its own run. `complete` is terminal for both
`succeeded` and `failed`, and the outcome is readable; retry policy lives above the queue, as a new
item.

The Wave 0 `EventLog` port (synchronous, backed by the existing `bun:sqlite` events table) is
transitional. It has no production callers, and its synchronous API cannot be implemented on
Postgres. `RunJournal` absorbs it in Wave 1; it never gets a Postgres adapter.

Adapters: SQLite for M1 (Wave 1), Postgres for M2/M3 (Wave 2). Both, and the in-memory fake, are
held to one suite, `src/testing/contracts/durability-contract.ts`. Orchestration decisions stay in
a pure `decide(state, event) → Command`, so an engine could interpret them later. No external
workflow engine is used.

## Consequences
- About 600–1,000 lines of owned, correctness-critical code, guarded by the contract suite and
  crash-injection tests.
- M2 and M3 need one Postgres reachable from every machine. Workers pull over outbound connections,
  so they work behind NAT.
- Labels become a display mirror. SSH rebalance, SSH event tail and `machine-health.json` failover
  are retired.

Revisit (spec §9; reviewed in Wave 5 and whenever a trigger fires):
- **Temporal, Cloud first,** if M3 passes ~10 machines or spans organizations; runs need
  intra-stage sagas or fan-out; the owned code passes ~2,000 LOC or causes more than 2 correctness
  incidents; or Temporal ships GA Bun workers and a TypeScript Agent SDK integration.
- **Temporal Cloud as the M3 service** if no shared Postgres will be run.
- **DBOS** if it gains SQLite and Bun support.
- **Restate** if it ships a self-hosted pull or outbound-tunnel mode.
