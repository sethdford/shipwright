# Power User Tips

Patterns and tricks for getting the most out of Claude Code Agent Teams with tmux.

---

## Team Patterns That Actually Work

Based on [Addy Osmani's research](https://addyosmani.com/blog/claude-code-agent-teams/) and community experience:

### When Teams Add Value

- **Competing hypotheses** — Multiple agents investigating different theories for a bug
- **Parallel review** — Security, performance, and test coverage by dedicated reviewers
- **Cross-layer features** — Frontend, backend, and tests developed simultaneously

### When to Stay Single-Agent

- Sequential, tightly-coupled work where each step depends on the last
- Simple bugs or single-file changes
- Tasks where coordination overhead exceeds the parallel benefit

### The Task Sizing Sweet Spot

Too small and coordination overhead dominates. Too large and agents work too long without check-ins. Aim for **5-6 focused tasks per agent** with clear deliverables.

### Specification Quality = Output Quality

Detailed spawn prompts with technical constraints, acceptance criteria, and domain context produce dramatically better results. Don't just say "fix the tests" — say "fix the auth tests in src/auth/**tests**/, ensuring all edge cases for expired tokens are covered, using the existing MockAuthProvider pattern."

---

## Hook Patterns for Teams

### Quality Gates (Most Valuable)

- **TeammateIdle** — Run typecheck before letting agents idle. Catches errors early.
- **TaskCompleted** — Run lint + related tests before allowing task completion.
- **Stop** — Verify all work is complete before Claude stops responding.

### Observability

- **Notification** — Desktop alerts so you can work on other things.
- **PostToolUse** on `Bash` — Log all commands agents run to a file.
- **SubagentStart/SubagentStop** — Track when agents spawn and finish.

### Context Preservation

- **PreCompact** — Save git status, recent commits, and project reminders before compaction.
- **SessionStart** on `compact` — Re-inject critical context after compaction.

---

## Team Size & Structure

### Keep teams small

Limit teams to **2-3 agents**. More agents increase the risk of the tmux `send-keys` race condition (#23615) and create more coordination overhead than they save in parallel work.

```
Good:  2 agents — backend + frontend
Good:  3 agents — backend + frontend + tests
Risky: 4+ agents — race conditions, context pressure
```

### Assign different files to each agent

File conflicts are the #1 source of wasted work in agent teams. If two agents edit the same file, one will overwrite the other. Always partition work by file ownership:

```
Agent 1 (backend):  src/api/, src/services/
Agent 2 (frontend): apps/web/src/
Agent 3 (tests):    src/tests/, *.test.ts
```

### Use git worktrees for complete isolation

For maximum safety, use [git worktrees](https://git-scm.com/docs/git-worktree) so each agent works in its own copy of the repo:

```bash
# Create worktrees for each agent
git worktree add ../project-backend feature/backend
git worktree add ../project-frontend feature/frontend
git worktree add ../project-tests feature/tests

# Each agent works in its own directory — zero conflict risk
```

---

## Agent Configuration

### Use `delegate` mode for maximum autonomy

When you trust the agents to work independently (e.g., they have clear, well-scoped tasks), use `delegate` mode to minimize permission prompts:

```bash
# In your Claude Code launch or CLAUDE.md
# "mode": "delegate" gives agents more autonomy
```

### Use haiku for subagent lookups

Subagents (spawned via the `Task` tool) don't need a powerful model for simple file searches and code lookups. Save money and latency:

```json
{
  "env": {
    "CLAUDE_CODE_SUBAGENT_MODEL": "haiku"
  }
}
```

### Prevent context overflow

Agent teams burn through context faster than solo sessions. Set aggressive auto-compact:

```json
{
  "env": {
    "CLAUDE_CODE_AUTOCOMPACT_PCT_OVERRIDE": "70"
  }
}
```

This compacts the conversation when it hits 70% of the context window (default is 80%).

---

## Monitoring & Management

### Watch all agents at once

Use `shipwright status` (alias: `sw`) to see a dashboard of running team sessions:

```bash
shipwright status
```

Or press `prefix + Ctrl-t` in tmux to show the dashboard inline.

### Zoom into a single agent

Press `prefix + G` to toggle zoom on the current pane. This makes one agent fill the entire terminal — useful for reading long output. Press again to return to the tiled layout.

### Synchronized input

Press `prefix + S` or `prefix + Alt-t` (M-t) to toggle synchronized panes. When enabled, anything you type goes to ALL panes simultaneously. Useful for:

- Stopping all agents at once (`Ctrl-C` in all panes)
- Running the same command in all agent directories

**Remember to turn it off** when you're done — otherwise your input goes everywhere.

### Capture pane contents

Press `prefix + Alt-s` (M-s) to save the current pane's visible content to a file in `/tmp/`. Useful for debugging agent output after the fact.

---

## Hook Patterns

### Quality gates

The included `teammate-idle.sh` hook blocks agents from going idle until TypeScript errors are fixed. You can extend this pattern for other checks:

```bash
# Example: lint check on idle
#!/usr/bin/env bash
cd "$(find_project_root)" || exit 0
pnpm lint 2>&1 || {
  echo "::error::Lint errors found. Fix them before going idle."
  exit 2
}
exit 0
```

### Notification sounds

Play a sound when an agent completes a task (macOS):

```bash
# task-completed.sh
#!/usr/bin/env bash
afplay /System/Library/Sounds/Glass.aiff &
exit 0
```

### Auto-format on save

Run a formatter when agents complete work:

```bash
# task-completed.sh
#!/usr/bin/env bash
cd "$(find_project_root)" || exit 0
pnpm format --write 2>&1
exit 0
```

---

## Task Design

### Write focused task descriptions

Vague tasks lead to wasted context and unfocused work. Compare:

```
Bad:  "Improve the authentication system"
Good: "Add rate limiting to POST /api/auth/login — max 5 attempts per
       IP per minute. Add the rate limiter in src/api/middleware/
       and tests in src/tests/auth-rate-limit.test.ts"
```

### 5-6 tasks per agent is the sweet spot

Too few tasks = agent finishes early and sits idle. Too many = context pressure and loss of focus.

### Put dependencies first

When creating task lists, order tasks so independent work comes first and dependent tasks come later. The team lead should assign blocked tasks only after their dependencies are complete.

---

## tmux Session Management

### Named sessions

Always use named sessions so you can find them later:

```bash
tmux new -s my-feature    # Not just "tmux new"
```

### Detach and reattach

You can detach from a session (`prefix + d`) and agents keep running. Reattach later:

```bash
tmux attach -t my-feature
```

### Clean up orphaned sessions

After a team finishes, clean up leftover tmux sessions and panes:

```bash
shipwright cleanup           # Dry-run: shows what would be killed
shipwright cleanup --force   # Actually kills orphaned sessions
```

---

## Environment Variables Reference

| Variable                                        | Default        | What it does                                                      |
| ----------------------------------------------- | -------------- | ----------------------------------------------------------------- |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`          | —              | **Required.** Enables agent teams feature                         |
| `CLAUDE_CODE_SUBAGENT_MODEL`                    | (parent model) | Model for subagent lookups. Set to `"haiku"` to save money        |
| `CLAUDE_CODE_AUTOCOMPACT_PCT_OVERRIDE`          | `"80"`         | Context compaction threshold. Lower = more aggressive             |
| `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY`          | `"3"`          | Parallel tool calls per agent. Higher = faster but more API usage |
| `CLAUDE_CODE_GLOB_HIDDEN`                       | —              | Include dotfiles in glob searches                                 |
| `CLAUDE_CODE_BASH_MAINTAIN_PROJECT_WORKING_DIR` | —              | Keep bash cwd consistent across tool calls                        |
| `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES`           | —              | Show tool use summaries in output                                 |
| `CLAUDE_CODE_TST_NAMES_IN_MESSAGES`             | —              | Show teammate names in messages                                   |
| `CLAUDE_CODE_EAGER_FLUSH`                       | —              | Flush output eagerly (reduces perceived latency)                  |

---

## Wave-Style Iteration

For complex, multi-step tasks, use **wave patterns** — iterative cycles of parallel agent work followed by synthesis. See the full pattern guides in [docs/patterns/](patterns/).

### The Wave Cycle

Each wave follows four steps:

1. **Assess** — Read agent outputs from the previous wave. What succeeded? What failed?
2. **Decompose** — What work remains? What can run in parallel?
3. **Spawn** — Launch agents in separate tmux panes for each independent task
4. **Synthesize** — Gather results, update the state file, plan the next wave

Repeat until done. Set a reasonable wave limit (5-10 for most tasks).

### File-Based State

Track progress through a markdown state file instead of keeping everything in agent memory. This survives compactions, context resets, and lets any agent pick up where others left off.

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
- [x] Built User model

## In Progress

- [ ] JWT route handlers
- [ ] React login components

## Blocked

- Integration tests blocked on route completion
```

**Agent outputs:** `.claude/team-outputs/*.md`

Each agent writes findings/results to a file in this directory. The team lead reads all outputs between waves.

**Add to `.gitignore`:**

```
.claude/team-state.local.md
.claude/team-outputs/
```

### When to Use Waves vs. Single-Pass Teams

| Situation                                                            | Approach                                                          |
| -------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Independent tasks with clear file ownership                          | Single-pass team — spawn agents, collect results                  |
| Tasks that require iteration (tests must pass, errors must be fixed) | Wave pattern — iterate until completion criteria met              |
| Exploratory work that builds on previous findings                    | Wave pattern — each wave goes deeper based on last wave's results |
| Simple parallel review (code quality + security + tests)             | Single-pass team — each reviewer works independently              |

### Quick Reference: Five Wave Patterns

| Pattern                                                      | Waves | Agents | Best For                    |
| ------------------------------------------------------------ | ----- | ------ | --------------------------- |
| [Feature Implementation](patterns/feature-implementation.md) | 3-4   | 2-3    | Multi-component features    |
| [Research & Exploration](patterns/research-exploration.md)   | 2-3   | 2-3    | Understanding codebases     |
| [Test Generation](patterns/test-generation.md)               | 3-4+  | 2-3    | Coverage campaigns          |
| [Refactoring](patterns/refactoring.md)                       | 3-4   | 2      | Large-scale transformations |
| [Bug Hunt](patterns/bug-hunt.md)                             | 3-4   | 2-3    | Complex, elusive bugs       |

---

## Shipwright-Specific Tips

### Use `--worktree` for parallel builds

When running multiple agents or pipelines concurrently, use worktree isolation to avoid conflicts:

```bash
shipwright pipeline start --issue 42 --worktree
shipwright loop "Refactor auth" --agents 2 --worktree
```

### Keep docs in sync

```bash
shipwright docs check   # Report stale AUTO sections (exit 1 if any)
shipwright docs sync   # Regenerate all stale sections
```

### Definition of Done for loops

Use a DoD file with `shipwright loop` to prevent premature completion:

```bash
shipwright loop "Add RBAC" --quality-gates --definition-of-done dod.md
```

Template at `docs/definition-of-done.example.md` (or `~/.shipwright/templates/` after install).

### Run all test suites

```bash
npm test              # All 96+ test suites
./scripts/sw-pipeline-test.sh   # Pipeline tests only (no real Claude/GitHub)
```
