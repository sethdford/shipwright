# Wave-Style Team Patterns

Structured patterns for running Claude Code Agent Teams in tmux using iterative, parallel "waves" of work.

---

## What Are Wave Patterns?

A **wave** is a cycle of parallel work followed by synthesis. Instead of one agent grinding through a task sequentially, you decompose work into independent chunks, assign them to agents in separate tmux panes, and iterate until done.

```
Wave 1: Research       Wave 2: Build           Wave 3: Integrate
┌─────┬─────┐          ┌─────┬─────┬─────┐     ┌─────┬─────┐
│ A1  │ A2  │    →     │ A1  │ A2  │ A3  │  →  │ A1  │ A2  │
│scan │scan │          │model│routes│ UI  │     │wire │tests│
└─────┴─────┘          └─────┴─────┴─────┘     └─────┴─────┘
      ↓ synthesize            ↓ synthesize            ↓ done
```

Each wave:

1. **Assess** — What did the previous wave accomplish? What failed?
2. **Decompose** — What can be done in parallel now?
3. **Spawn** — Launch agents in tmux panes for each independent task
4. **Synthesize** — Gather results, update state, plan next wave

---

## Available Patterns

| Pattern                                             | When to Use                               | Typical Waves | Team Size  |
| --------------------------------------------------- | ----------------------------------------- | ------------- | ---------- |
| [Feature Implementation](feature-implementation.md) | Building multi-component features         | 3-4           | 2-3 agents |
| [Research & Exploration](research-exploration.md)   | Understanding a codebase or problem space | 2-3           | 2-3 agents |
| [Test Generation](test-generation.md)               | Comprehensive test coverage campaigns     | 3-4+          | 2-3 agents |
| [Refactoring](refactoring.md)                       | Large-scale code transformations          | 3-4           | 2 agents   |
| [Bug Hunt](bug-hunt.md)                             | Tracking down complex, elusive bugs       | 3-4           | 2-3 agents |
| [Audit Loop](audit-loop.md)                         | Self-reflection, quality gates in loop    | N/A           | 1-2 agents |

---

## File-Based State

Wave patterns use a **file-based state file** to track progress across iterations. This works everywhere — no special tools required.

**State file:** `.claude/team-state.local.md`

```markdown
---
wave: 2
status: in_progress
goal: "Build user auth with JWT"
started_at: 2026-02-07T10:00:00Z
---

## Completed

- [x] Scanned existing auth patterns
- [x] Identified middleware structure
- [x] Built User model

## In Progress

- [ ] JWT route handlers
- [ ] Login/signup React components

## Blocked

- None

## Agent Outputs

- wave-1-scan-auth.md — Existing auth analysis
- wave-1-scan-deps.md — Dependency audit
- wave-2-model.md — User model implementation notes
```

**Agent outputs directory:** `.claude/team-outputs/`

Each agent writes its results to a markdown file in this directory. The team lead reads all outputs between waves to synthesize progress.

> **Tip:** Add `.claude/team-state.local.md` and `.claude/team-outputs/` to your `.gitignore`. These are ephemeral working files.

---

## Quick Start

Pick a pattern, then use `shipwright` (alias: `sw`) to set up the team:

```bash
# Start a tmux session
tmux new -s my-feature

# Create a 3-agent team
shipwright session my-feature

# In the team lead pane, describe the work using a wave pattern
# The team lead decomposes into waves and assigns tasks
```

---

## Key Principles

### 1. Parallel Everything

If two tasks don't depend on each other, run them at the same time in separate panes. The whole point of waves is maximizing parallel throughput.

### 2. Synthesize Between Waves

Don't just fire-and-forget. After each wave, the team lead reads all agent outputs, identifies gaps, and adjusts the plan. This is where the real value happens.

### 3. Iterate Until Done

Waves repeat until the goal is met. Failed tasks get retried with better instructions. Each wave builds on the last. Set a reasonable max (5-10 waves for most tasks).

### 4. File-Based State Is the Source of Truth

The `.claude/team-state.local.md` file tracks what's done, what's pending, and what's blocked. Agents update their output files; the team lead updates the state file.

### 5. Keep Teams Small

2-3 agents per team. More agents means more tmux panes, more coordination overhead, and more risk of file conflicts. The sweet spot is 2-3 focused agents.

---

## Anti-Patterns

| Don't                              | Why                                              | Instead                                            |
| ---------------------------------- | ------------------------------------------------ | -------------------------------------------------- |
| Spawn 5+ agents per wave           | Coordination overhead, race conditions           | 2-3 agents per wave                                |
| Skip synthesis between waves       | You'll lose track of progress and duplicate work | Always read outputs and update state               |
| Give vague task descriptions       | Agents waste context figuring out what to do     | Be specific: files, functions, acceptance criteria |
| Let agents touch overlapping files | One will overwrite the other's changes           | Partition files by agent                           |
| Keep iterating when stuck          | Wastes tokens and your time                      | After 3 failed attempts, rethink the approach      |
| Use waves for trivial tasks        | Overhead exceeds benefit                         | Just do it in a single agent                       |

---

## Model Selection

Choose the right model for each agent's task:

| Task Type                                 | Model    | Why                    |
| ----------------------------------------- | -------- | ---------------------- |
| File search, simple lookups               | `haiku`  | Fast, cheap            |
| Implementation, clear requirements        | `sonnet` | Balanced speed/quality |
| Architecture decisions, complex debugging | `opus`   | Best reasoning         |
| Test generation                           | `sonnet` | Good pattern matching  |
| Documentation, reports                    | `sonnet` | Clear writing          |

---

See also: [docs/README.md](../README.md) — Documentation hub
