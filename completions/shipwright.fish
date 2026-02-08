# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Fish tab completions                                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Place in ~/.config/fish/completions/

# Disable file completions by default
for cmd in shipwright sw cct
    complete -c $cmd -f

    # Top-level commands
    set -l all_cmds session status ps logs templates doctor cleanup reaper upgrade loop pipeline worktree prep daemon memory cost init help version
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
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l test-cmd -d "Test command to verify each iteration" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l max-iterations -d "Maximum loop iterations" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l model -d "Claude model to use" -ra "opus sonnet haiku"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l agents -d "Number of agents" -r
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l audit -d "Enable self-reflection each iteration"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l audit-agent -d "Use separate auditor agent"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l quality-gates -d "Enable automated quality checks"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l definition-of-done -d "Custom completion checklist" -rF
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l resume -d "Resume interrupted loop"
    complete -c $cmd -n "__fish_seen_subcommand_from loop" -l skip-permissions -d "Skip permission prompts"

    # logs flags
    complete -c $cmd -n "__fish_seen_subcommand_from logs" -l follow -d "Tail logs in real time"
    complete -c $cmd -n "__fish_seen_subcommand_from logs" -l lines -d "Number of lines to show" -r

    # cleanup flags
    complete -c $cmd -n "__fish_seen_subcommand_from cleanup" -l force -d "Actually kill orphaned sessions"

    # upgrade flags
    complete -c $cmd -n "__fish_seen_subcommand_from upgrade" -l apply -d "Apply available updates"

    # reaper flags
    complete -c $cmd -n "__fish_seen_subcommand_from reaper" -l watch -d "Continuous watch mode"
end
