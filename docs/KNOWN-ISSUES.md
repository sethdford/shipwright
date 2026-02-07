# Known Issues

Tracked bugs and limitations in Claude Code Agent Teams + tmux integration, with workarounds.

---

## #23615: tmux `send-keys` race condition

**Severity:** Medium — affects sessions with 4+ agents

**Problem:** When Claude Code spawns 4+ agent panes simultaneously using `split-window` + `send-keys`, tmux can deliver keystrokes to the wrong pane. This happens because tmux processes `split-window` and `send-keys` asynchronously — the new pane may not be the active pane by the time `send-keys` fires.

**Symptoms:**
- Agent commands appear in the wrong pane
- Panes start with garbled or partial commands
- Some panes sit empty while others received duplicate input

**Workaround:** The `cct` CLI uses `new-window` instead of `split-window` for spawning agent panes, then arranges them with `select-layout tiled` after all panes are created. This avoids the race because each `new-window` creates an isolated context.

If spawning panes manually, add a small delay between operations:

```bash
tmux split-window -t "$session" -h
sleep 0.1
tmux send-keys -t "$session" "claude" Enter
```

**Root cause:** This is a fundamental tmux limitation, not a Claude Code bug. tmux's command queue doesn't guarantee ordering between window operations and key delivery.

**Status:** Open — no upstream fix expected. The `cct` workaround is reliable.

---

## #23572: Silent fallback to in-process mode

**Severity:** Low — cosmetic, but confusing

**Problem:** Agent teams can silently fall back to in-process mode if tmux isn't detected properly. No error is shown — agents just spawn in the same process instead of separate panes.

**Symptoms:**
- You're inside tmux but agents don't get their own panes
- All agent output appears in a single terminal
- No tmux split-windows are created

**Workaround:** Make sure you're inside a real tmux session (not a nested one) and that `$TMUX` is set:

```bash
echo $TMUX  # Should show the tmux socket path
tmux new -s dev  # Start a session if not in one
```

Claude Code auto-detects tmux and uses split panes when available.

**How to verify:** After launching a team, check for multiple tmux panes:

```bash
tmux list-panes
```

If only one pane is listed while agents are active, the fallback occurred.

**Status:** Open — tracked in Claude Code issue tracker.

---

## No VS Code / Ghostty terminal support

**Severity:** Medium — affects users of these terminals

**Problem:** Claude Code's tmux-based agent pane spawning does not work in:
- **VS Code's integrated terminal** — VS Code's terminal emulator doesn't support the tmux control mode and pane management that Claude Code uses for agent teams.
- **Ghostty** — As of current versions, Ghostty lacks the tmux integration hooks needed for split-pane agent spawning.

**Symptoms:**
- Agent teams silently fall back to in-process mode
- No tmux split panes are created
- Everything works, but you lose the visual multi-pane experience

**Workaround:** Use a supported terminal emulator:

| Terminal | Status | Notes |
|----------|--------|-------|
| **iTerm2** (macOS) | Supported | Recommended for macOS |
| **Alacritty** | Supported | Fast, cross-platform |
| **Kitty** | Supported | Feature-rich, cross-platform |
| **WezTerm** | Supported | Cross-platform, GPU-accelerated |
| **macOS Terminal.app** | Supported | Built-in, basic but works |
| VS Code terminal | Not supported | Use an external terminal |
| Ghostty | Not supported | May be supported in future versions |

**Tip:** You can run tmux in an external terminal while keeping VS Code open for editing. Claude Code doesn't need to run inside VS Code to work with your project.

**Status:** Unlikely to change — this is a terminal emulator limitation, not a Claude Code bug.

---

## Context window pressure with large teams

**Severity:** Low — manageable with good practices

**Problem:** Each agent in a team uses its own context window. With 3+ agents running complex tasks, individual agents can hit context limits faster than expected, especially if tasks are too broad.

**Symptoms:**
- Agent output becomes less coherent toward the end of long tasks
- Agents start losing track of earlier context
- Auto-compact kicks in frequently

**Workaround:**

1. **Limit teams to 2-3 agents.** More agents means more total context usage and more coordination overhead.

2. **Keep tasks focused.** 5-6 specific tasks per agent is the sweet spot. Avoid vague tasks like "improve the codebase."

3. **Set aggressive auto-compact:**
   ```json
   {
     "env": {
       "CLAUDE_CODE_AUTOCOMPACT_PCT_OVERRIDE": "70"
     }
   }
   ```

4. **Use haiku for subagent lookups** to save context budget for the main agent:
   ```json
   {
     "env": {
       "CLAUDE_CODE_SUBAGENT_MODEL": "haiku"
     }
   }
   ```

5. **Assign different files** to each agent to reduce cross-referencing needs.

**Status:** By design — context windows are finite. The workarounds above mitigate the issue effectively.

---

## TPM plugins not loading

**Severity:** Low — cosmetic

**Problem:** After installation, tmux plugins (resurrect, continuum) don't load until TPM is initialized.

**Workaround:** Press `prefix + I` (capital I) after starting tmux to install plugins. This only needs to be done once.

If TPM itself isn't installed, the installer will offer to install it, or you can install manually:

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

**Status:** Expected behavior — TPM requires a one-time plugin install step.
