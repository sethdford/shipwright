# Power User Tips

Patterns and tricks for getting the most out of Claude Code Agent Teams with tmux.

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

Use `cct status` to see a dashboard of running team sessions:

```bash
cct status
```

Or press `prefix + Ctrl-t` in tmux to show the dashboard inline.

### Zoom into a single agent

Press `prefix + G` to toggle zoom on the current pane. This makes one agent fill the entire terminal — useful for reading long output. Press again to return to the tiled layout.

### Synchronized input

Press `prefix + Alt-t` to toggle synchronized panes. When enabled, anything you type goes to ALL panes simultaneously. Useful for:
- Stopping all agents at once (`Ctrl-C` in all panes)
- Running the same command in all agent directories

**Remember to turn it off** when you're done — otherwise your input goes everywhere.

### Capture pane contents

Press `prefix + Alt-s` to save the current pane's visible content to a file in `/tmp/`. Useful for debugging agent output after the fact.

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
cct cleanup           # Dry-run: shows what would be killed
cct cleanup --force   # Actually kills orphaned sessions
```

---

## Environment Variables Reference

| Variable | Default | What it does |
|----------|---------|--------------|
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | — | **Required.** Enables agent teams feature |
| `CLAUDE_CODE_SUBAGENT_MODEL` | (parent model) | Model for subagent lookups. Set to `"haiku"` to save money |
| `CLAUDE_CODE_AUTOCOMPACT_PCT_OVERRIDE` | `"80"` | Context compaction threshold. Lower = more aggressive |
| `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY` | `"3"` | Parallel tool calls per agent. Higher = faster but more API usage |
| `CLAUDE_CODE_GLOB_HIDDEN` | — | Include dotfiles in glob searches |
| `CLAUDE_CODE_BASH_MAINTAIN_PROJECT_WORKING_DIR` | — | Keep bash cwd consistent across tool calls |
| `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES` | — | Show tool use summaries in output |
| `CLAUDE_CODE_TST_NAMES_IN_MESSAGES` | — | Show teammate names in messages |
| `CLAUDE_CODE_EAGER_FLUSH` | — | Flush output eagerly (reduces perceived latency) |
