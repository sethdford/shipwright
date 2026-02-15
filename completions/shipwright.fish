# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Fish tab completions                                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Place in ~/.config/fish/completions/

# Disable file completions by default
for cmd in shipwright sw cct
    complete -c $cmd -f

    # Top-level commands (includes groups and flat commands)
    set -l all_cmds agent quality observe release intel session status ps logs templates doctor cleanup reaper upgrade loop pipeline worktree prep daemon memory cost init help version
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "agent" -d "Agent management (recruit, swarm, standup, guild, oversight)"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "quality" -d "Quality & review (code-review, security-audit, testgen, hygiene)"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "observe" -d "Observability (vitals, dora, retro, stream, activity, replay)"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "release" -d "Release & deploy (release, release-manager, changelog, deploy)"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "intel" -d "Intelligence (predict, intelligence, strategic, optimize)"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "session" -d "Create a new tmux window for a Claude team"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "status" -d "Show dashboard of running teams and agents"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "ps" -d "Show running agent processes and status"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "logs" -d "View and search agent pane logs"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "templates" -d "Manage team composition templates"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "doctor" -d "Validate your setup and check for issues"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "cleanup" -d "Clean up orphaned team sessions"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "reaper" -d "Automatic pane cleanup when agents exit"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "upgrade" -d "Check for updates from the repo"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "loop" -d "Continuous agent loop"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "pipeline" -d "Full delivery pipeline"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "worktree" -d "Manage git worktrees"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "prep" -d "Repo preparation"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "daemon" -d "Issue watcher daemon"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "memory" -d "Persistent memory system"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "cost" -d "Cost intelligence"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "init" -d "Quick tmux setup"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "help" -d "Show help message"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "version" -d "Show version"

    # agent subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from agent" -a "recruit" -d "Agent recruitment & talent management"
    complete -c $cmd -n "__fish_seen_subcommand_from agent" -a "swarm" -d "Dynamic agent swarm management"
    complete -c $cmd -n "__fish_seen_subcommand_from agent" -a "standup" -d "Automated daily standups"
    complete -c $cmd -n "__fish_seen_subcommand_from agent" -a "guild" -d "Knowledge guilds & cross-team learning"
    complete -c $cmd -n "__fish_seen_subcommand_from agent" -a "oversight" -d "Quality oversight board"

    # quality subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from quality" -a "code-review" -d "Clean code & architecture analysis"
    complete -c $cmd -n "__fish_seen_subcommand_from quality" -a "security-audit" -d "Comprehensive security auditing"
    complete -c $cmd -n "__fish_seen_subcommand_from quality" -a "testgen" -d "Autonomous test generation"
    complete -c $cmd -n "__fish_seen_subcommand_from quality" -a "hygiene" -d "Repository organization & cleanup"

    # observe subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from observe" -a "vitals" -d "Pipeline vitals — real-time scoring"
    complete -c $cmd -n "__fish_seen_subcommand_from observe" -a "dora" -d "DORA metrics dashboard"
    complete -c $cmd -n "__fish_seen_subcommand_from observe" -a "retro" -d "Sprint retrospective engine"
    complete -c $cmd -n "__fish_seen_subcommand_from observe" -a "stream" -d "Live terminal output streaming"
    complete -c $cmd -n "__fish_seen_subcommand_from observe" -a "activity" -d "Live agent activity stream"
    complete -c $cmd -n "__fish_seen_subcommand_from observe" -a "replay" -d "Pipeline DVR — view past runs"
    complete -c $cmd -n "__fish_seen_subcommand_from observe" -a "status" -d "Team status dashboard"

    # release subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from release" -a "release" -d "Release train automation"
    complete -c $cmd -n "__fish_seen_subcommand_from release" -a "release-manager" -d "Autonomous release pipeline"
    complete -c $cmd -n "__fish_seen_subcommand_from release" -a "changelog" -d "Automated release notes"
    complete -c $cmd -n "__fish_seen_subcommand_from release" -a "deploy" -d "Deployments — deployment history"

    # intel subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from intel" -a "predict" -d "Predictive risk assessment"
    complete -c $cmd -n "__fish_seen_subcommand_from intel" -a "intelligence" -d "Intelligence engine analysis"
    complete -c $cmd -n "__fish_seen_subcommand_from intel" -a "strategic" -d "Strategic intelligence agent"
    complete -c $cmd -n "__fish_seen_subcommand_from intel" -a "optimize" -d "Self-optimization based on DORA"

    # pipeline subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -a "start" -d "Start a new pipeline run"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -a "resume" -d "Resume from last stage"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -a "status" -d "Show pipeline progress"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -a "abort" -d "Cancel the running pipeline"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -a "list" -d "Browse pipeline templates"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -a "show" -d "Show pipeline template details"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -a "test" -d "Run pipeline test suite"

    # daemon subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -a "start" -d "Start issue watcher"
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -a "stop" -d "Graceful shutdown"
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -a "status" -d "Show active pipelines"
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -a "metrics" -d "DORA/DX metrics dashboard"
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -a "triage" -d "Show issue triage scores"
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -a "patrol" -d "Run proactive codebase patrol"
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -a "test" -d "Run daemon test suite"
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -a "logs" -d "View daemon logs"
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -a "init" -d "Initialize daemon config"

    # memory subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from memory" -a "show" -d "Show learned patterns"
    complete -c $cmd -n "__fish_seen_subcommand_from memory" -a "search" -d "Search across memories"
    complete -c $cmd -n "__fish_seen_subcommand_from memory" -a "forget" -d "Remove a memory entry"
    complete -c $cmd -n "__fish_seen_subcommand_from memory" -a "export" -d "Export memories to file"
    complete -c $cmd -n "__fish_seen_subcommand_from memory" -a "import" -d "Import memories from file"
    complete -c $cmd -n "__fish_seen_subcommand_from memory" -a "stats" -d "Memory usage and coverage"
    complete -c $cmd -n "__fish_seen_subcommand_from memory" -a "test" -d "Run memory test suite"

    # cost subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -a "show" -d "Show cost summary"
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -a "budget" -d "Manage daily budget"
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -a "record" -d "Record token usage"
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -a "calculate" -d "Calculate cost estimate"
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -a "check-budget" -d "Check budget before starting"

    # cost show flags
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -l period -d "Number of days to report" -r
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -l json -d "JSON output"
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -l by-stage -d "Breakdown by pipeline stage"
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -l by-issue -d "Breakdown by issue"

    # templates subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from templates" -a "list" -d "Browse team templates"
    complete -c $cmd -n "__fish_seen_subcommand_from templates" -a "show" -d "Show template details"

    # prep flags
    complete -c $cmd -n "__fish_seen_subcommand_from prep" -l check -d "Audit existing prep quality"
    complete -c $cmd -n "__fish_seen_subcommand_from prep" -l with-claude -d "Deep analysis using Claude Code"
    complete -c $cmd -n "__fish_seen_subcommand_from prep" -l verbose -d "Verbose output"

    # loop flags
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l repo -d "Change to directory before running" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l local -d "Local-only mode (no GitHub)"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l test-cmd -d "Test command to verify each iteration" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l fast-test-cmd -d "Fast/subset test command" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l fast-test-interval -d "Run full tests every N iterations" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l max-iterations -d "Maximum loop iterations" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l model -d "Claude model to use" -ra "opus sonnet haiku"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l agents -d "Number of agents" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l roles -d "Role per agent" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l worktree -d "Use git worktrees for isolation"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l audit -d "Enable self-reflection each iteration"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l audit-agent -d "Use separate auditor agent"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l quality-gates -d "Enable automated quality checks"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l definition-of-done -d "Custom completion checklist" -rF
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l no-auto-extend -d "Disable auto-extension"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l extension-size -d "Additional iterations per extension" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l max-extensions -d "Max number of auto-extensions" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l resume -d "Resume interrupted loop"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l max-restarts -d "Max session restarts" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l max-turns -d "Max API turns per session" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l skip-permissions -d "Skip permission prompts"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l verbose -d "Show full Claude output"

    # logs flags
    complete -c $cmd -n "__fish_seen_subcommand_from logs" -l follow -d "Tail logs in real time"
    complete -c $cmd -n "__fish_seen_subcommand_from logs" -l lines -d "Number of lines to show" -r

    # cleanup flags
    complete -c $cmd -n "__fish_seen_subcommand_from cleanup" -l force -d "Actually kill orphaned sessions"

    # upgrade flags
    complete -c $cmd -n "__fish_seen_subcommand_from upgrade" -l apply -d "Apply available updates"

    # reaper flags
    complete -c $cmd -n "__fish_seen_subcommand_from reaper" -l watch -d "Continuous watch mode"

    # pipeline flags
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l issue -d "GitHub issue number" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l goal -d "Goal description" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l repo -d "Change to directory before running" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l local -d "Local-only mode (no GitHub)"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l pipeline -d "Pipeline template" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l template -d "Pipeline template" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l test-cmd -d "Test command to run" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l model -d "AI model to use" -ra "opus sonnet haiku"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l agents -d "Number of agents" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l skip-gates -d "Auto-approve all gates"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l base -d "Base branch for PR" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l reviewers -d "PR reviewers" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l labels -d "PR labels" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l no-github -d "Disable GitHub integration"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l no-github-label -d "Don't modify issue labels"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l ci -d "CI mode (non-interactive)"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l ignore-budget -d "Skip budget enforcement"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l worktree -d "Run in isolated worktree"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l dry-run -d "Show what would happen"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l slack-webhook -d "Slack webhook URL" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l self-heal -d "Build retry cycles" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l max-iterations -d "Max build loop iterations" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l max-restarts -d "Max session restarts" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l fast-test-cmd -d "Fast/subset test command" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l completed-stages -d "Skip these stages" -r
end
