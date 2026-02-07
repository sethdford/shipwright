<!-- LinkedIn Post — copy-paste ready -->

**I gave Claude Code a team of AI agents and a tmux session. Things got interesting.**

Picture this: three AI agents working in parallel — one building an API, one wiring up the UI, one writing tests — each in their own tmux pane, all visible on one screen. You can literally watch them think.

That's what Claude Code agent teams look like when you give them proper tooling.

I open-sourced the setup I've been refining: `cct` (Claude Code Teams). It's a CLI + tmux config that turns multi-agent AI development from chaotic to organized.

The highlight reel:

🔁 `cct loop` — Give it a goal, a test command, and walk away. It runs Claude in a build-test-review loop until everything passes. Autonomous coding that actually verifies its own work.

📋 12 team templates — Feature dev, bug fixes, security audits, migrations, code review, architecture planning. Each template assigns agents to separate files so they don't step on each other.

🚦 Quality gates — Agents can't mark work as "done" until typecheck, lint, and tests pass. No more "it works on my machine" from your AI teammates.

📐 Layout presets — Leader pane gets 65% of the screen. Because the agent running the show deserves the biggest monitor.

My favorite workflow so far:

    cct loop "Build user auth with JWT" --test-cmd "npm test" --audit

Walk away. Get coffee. Come back to a working feature with passing tests. (Okay, sometimes you come back to a very confident agent that's still arguing with TypeScript. But that's part of the fun.)

Pure bash + jq. No heavy dependencies.

Check it out → https://github.com/sethdford/shipwright

What's your multi-agent AI workflow look like? Drop your setup in the comments — I'm always looking for new patterns to steal. 😄

#ClaudeCode #AIEngineering #DeveloperTools #OpenSource #Anthropic
