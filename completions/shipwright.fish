# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Fish tab completions                                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Place in ~/.config/fish/completions/

# Disable file completions by default
for cmd in shipwright sw
    complete -c $cmd -f

    # All top-level commands (90+)
    set -l all_cmds agent quality observe release intel session status mission-control ps logs activity templates doctor cleanup reaper upgrade loop pipeline worktree prep hygiene daemon autonomous memory guild instrument cost adaptive regression incident db deps fleet fleet-viz fix init setup dashboard public-dashboard jira linear model tracker heartbeat standup checkpoint durable webhook connect remote launchd auth intelligence optimize predict adversarial simulation strategic architecture vitals stream docs changelog docs-agent doc-fleet release-manager replay review-rerun scale swarm dora retro tmux tmux-pipeline github checks ci deploys github-app decompose discovery context trace pr widgets feedback eventbus evidence otel triage pipeline-composer oversight code-review pm team-stages ux recruit testgen e2e security-audit help version

    # ─── Command groups ──────────────────────────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "agent" -d "Agent management (recruit, swarm, standup, guild, oversight)"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "quality" -d "Quality & review (code-review, security-audit, testgen, hygiene, validate)"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "observe" -d "Observability (vitals, dora, retro, stream, activity, replay)"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "release" -d "Release & deploy (release, release-manager, changelog, deploy, build)"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "intel" -d "Intelligence (predict, intelligence, strategic, optimize)"

    # ─── Core workflow ───────────────────────────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "session" -d "Create a new tmux window for a Claude team"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "status" -d "Show dashboard of running teams and agents"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "mission-control" -d "Terminal-based pipeline mission control"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "ps" -d "Show running agent processes and status"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "logs" -d "View and search agent pane logs"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "activity" -d "Live agent activity stream"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "templates" -d "Manage team composition templates"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "doctor" -d "Validate your setup and check for issues"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "cleanup" -d "Clean up orphaned team sessions"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "reaper" -d "Automatic pane cleanup when agents exit"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "upgrade" -d "Check for updates from the repo"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "loop" -d "Continuous agent loop"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "pipeline" -d "Full delivery pipeline"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "worktree" -d "Manage git worktrees"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "prep" -d "Repo preparation"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "hygiene" -d "Repository organization & cleanup"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "daemon" -d "Issue watcher daemon"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "autonomous" -d "AI-building-AI master controller"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "memory" -d "Persistent memory system"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "cost" -d "Cost intelligence"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "init" -d "Quick tmux setup"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "setup" -d "Guided setup wizard"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "help" -d "Show help message"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "version" -d "Show/bump/check version"

    # ─── Agent management (top-level shortcuts) ──────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "swarm" -d "Dynamic agent swarm management"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "recruit" -d "Agent recruitment & talent management"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "standup" -d "Automated daily standups"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "guild" -d "Knowledge guilds & cross-team learning"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "oversight" -d "Quality oversight board"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "pm" -d "Autonomous PM agent"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "team-stages" -d "Multi-agent execution with roles"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "scale" -d "Dynamic agent team scaling"

    # ─── Quality (top-level shortcuts) ───────────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "code-review" -d "Clean code & architecture analysis"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "security-audit" -d "Comprehensive security auditing"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "testgen" -d "Autonomous test generation"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "adversarial" -d "Red-team code review"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "simulation" -d "Multi-persona developer simulation"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "architecture" -d "Architecture model & enforcement"

    # ─── Observability (top-level shortcuts) ─────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "vitals" -d "Pipeline vitals — real-time scoring"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "dora" -d "DORA metrics dashboard"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "retro" -d "Sprint retrospective engine"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "stream" -d "Live terminal output streaming"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "replay" -d "Pipeline DVR — view past runs"

    # ─── Release (top-level shortcuts) ───────────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "changelog" -d "Automated release notes"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "release-manager" -d "Autonomous release pipeline"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "review-rerun" -d "SHA-deduped rerun comment writer"

    # ─── Intelligence (top-level shortcuts) ──────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "intelligence" -d "Intelligence engine analysis"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "predict" -d "Predictive risk assessment"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "strategic" -d "Strategic intelligence agent"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "optimize" -d "Self-optimization based on DORA"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "adaptive" -d "Data-driven pipeline tuning"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "regression" -d "Regression detection pipeline"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "model" -d "Intelligent model routing"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "pipeline-composer" -d "Dynamic pipeline composition"

    # ─── Operations ──────────────────────────────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "fleet" -d "Multi-repo daemon orchestration"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "fleet-viz" -d "Multi-repo fleet visualization"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "fix" -d "Bulk fix across repos"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "dashboard" -d "Real-time web dashboard"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "public-dashboard" -d "Public pipeline progress"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "connect" -d "Team connect — sync local state"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "remote" -d "Remote machine management"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "launchd" -d "Process supervision"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "heartbeat" -d "Agent heartbeat protocol"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "checkpoint" -d "Save/restore agent state"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "tmux-pipeline" -d "Spawn pipelines in tmux"

    # ─── Integrations ────────────────────────────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "jira" -d "Jira ↔ GitHub sync"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "linear" -d "Linear ↔ GitHub sync"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "tracker" -d "Issue tracker router"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "github" -d "GitHub context & metadata"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "github-app" -d "GitHub App management"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "checks" -d "GitHub check runs"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "ci" -d "CI/CD workflow generation"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "deploys" -d "Deployment history"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "webhook" -d "GitHub webhook receiver"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "auth" -d "GitHub OAuth authentication"

    # ─── Issue management ────────────────────────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "triage" -d "Issue labeling & prioritization"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "decompose" -d "Issue decomposition"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "pr" -d "PR lifecycle management"

    # ─── Data & learning ─────────────────────────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "db" -d "SQLite persistence layer"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "instrument" -d "Pipeline instrumentation"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "discovery" -d "Cross-pipeline learning"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "feedback" -d "Production feedback loop"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "eventbus" -d "Durable event bus"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "evidence" -d "Machine-verifiable proof"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "otel" -d "OpenTelemetry observability"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "context" -d "Context engine"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "trace" -d "E2E traceability"

    # ─── Documentation ───────────────────────────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "docs" -d "Documentation keeper"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "docs-agent" -d "Auto-sync README, wiki, API docs"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "doc-fleet" -d "Documentation fleet orchestrator"

    # ─── Advanced ────────────────────────────────────────────────────────
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "incident" -d "Incident detection & response"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "deps" -d "Dependency update management"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "durable" -d "Durable workflow engine"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "tmux" -d "tmux health & plugin management"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "ux" -d "Premium UX enhancement layer"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "widgets" -d "Embeddable status widgets"
    complete -c $cmd -n "not __fish_seen_subcommand_from $all_cmds" -a "e2e" -d "Test suite registry & execution"

    # ═══════════════════════════════════════════════════════════════════════
    # SUBCOMMANDS
    # ═══════════════════════════════════════════════════════════════════════

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
    complete -c $cmd -n "__fish_seen_subcommand_from quality" -a "validate" -d "Intelligent completion audits"
    complete -c $cmd -n "__fish_seen_subcommand_from quality" -a "gate" -d "Quality gate enforcement"

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
    complete -c $cmd -n "__fish_seen_subcommand_from release" -a "build" -d "Build release tarballs"

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

    # fleet subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from fleet" -a "start" -d "Start daemons for all repos"
    complete -c $cmd -n "__fish_seen_subcommand_from fleet" -a "stop" -d "Stop all daemons"
    complete -c $cmd -n "__fish_seen_subcommand_from fleet" -a "status" -d "Show fleet-wide status"
    complete -c $cmd -n "__fish_seen_subcommand_from fleet" -a "metrics" -d "Cross-repo DORA metrics"
    complete -c $cmd -n "__fish_seen_subcommand_from fleet" -a "discover" -d "Auto-discover repos"
    complete -c $cmd -n "__fish_seen_subcommand_from fleet" -a "test" -d "Run fleet test suite"

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
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -a "remaining-budget" -d "Check remaining daily budget"

    # templates subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from templates" -a "list" -d "Browse team templates"
    complete -c $cmd -n "__fish_seen_subcommand_from templates" -a "show" -d "Show template details"

    # worktree subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from worktree" -a "create" -d "Create git worktree"
    complete -c $cmd -n "__fish_seen_subcommand_from worktree" -a "list" -d "List active worktrees"
    complete -c $cmd -n "__fish_seen_subcommand_from worktree" -a "remove" -d "Remove worktree"

    # tracker subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from tracker" -a "init" -d "Initialize tracker"
    complete -c $cmd -n "__fish_seen_subcommand_from tracker" -a "status" -d "Show tracker status"
    complete -c $cmd -n "__fish_seen_subcommand_from tracker" -a "sync" -d "Sync issues"
    complete -c $cmd -n "__fish_seen_subcommand_from tracker" -a "test" -d "Run tracker test suite"

    # heartbeat subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from heartbeat" -a "write" -d "Write heartbeat"
    complete -c $cmd -n "__fish_seen_subcommand_from heartbeat" -a "check" -d "Check heartbeat"
    complete -c $cmd -n "__fish_seen_subcommand_from heartbeat" -a "list" -d "List heartbeats"
    complete -c $cmd -n "__fish_seen_subcommand_from heartbeat" -a "clear" -d "Clear heartbeats"

    # checkpoint subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from checkpoint" -a "save" -d "Save agent state"
    complete -c $cmd -n "__fish_seen_subcommand_from checkpoint" -a "restore" -d "Restore agent state"
    complete -c $cmd -n "__fish_seen_subcommand_from checkpoint" -a "list" -d "List checkpoints"
    complete -c $cmd -n "__fish_seen_subcommand_from checkpoint" -a "delete" -d "Delete checkpoint"

    # connect subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from connect" -a "start" -d "Sync to dashboard"
    complete -c $cmd -n "__fish_seen_subcommand_from connect" -a "stop" -d "Stop connection"
    complete -c $cmd -n "__fish_seen_subcommand_from connect" -a "join" -d "Join a team"
    complete -c $cmd -n "__fish_seen_subcommand_from connect" -a "status" -d "Show connection status"

    # remote subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from remote" -a "list" -d "Show remote machines"
    complete -c $cmd -n "__fish_seen_subcommand_from remote" -a "add" -d "Register a remote"
    complete -c $cmd -n "__fish_seen_subcommand_from remote" -a "remove" -d "Remove a remote"
    complete -c $cmd -n "__fish_seen_subcommand_from remote" -a "status" -d "Health check remotes"
    complete -c $cmd -n "__fish_seen_subcommand_from remote" -a "test" -d "Run remote test suite"

    # launchd subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from launchd" -a "install" -d "Auto-start on boot"
    complete -c $cmd -n "__fish_seen_subcommand_from launchd" -a "uninstall" -d "Remove services"
    complete -c $cmd -n "__fish_seen_subcommand_from launchd" -a "status" -d "Show service status"
    complete -c $cmd -n "__fish_seen_subcommand_from launchd" -a "test" -d "Run launchd test suite"

    # dashboard subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from dashboard" -a "start" -d "Start dashboard"
    complete -c $cmd -n "__fish_seen_subcommand_from dashboard" -a "stop" -d "Stop dashboard"
    complete -c $cmd -n "__fish_seen_subcommand_from dashboard" -a "status" -d "Show dashboard status"

    # github subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from github" -a "context" -d "Show GitHub context"
    complete -c $cmd -n "__fish_seen_subcommand_from github" -a "security" -d "Show security alerts"
    complete -c $cmd -n "__fish_seen_subcommand_from github" -a "blame" -d "Show file ownership"

    # checks subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from checks" -a "list" -d "Show check runs"
    complete -c $cmd -n "__fish_seen_subcommand_from checks" -a "status" -d "Show check status"
    complete -c $cmd -n "__fish_seen_subcommand_from checks" -a "test" -d "Run checks test suite"

    # deploys subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from deploys" -a "list" -d "Show deployment history"
    complete -c $cmd -n "__fish_seen_subcommand_from deploys" -a "status" -d "Show deployment status"
    complete -c $cmd -n "__fish_seen_subcommand_from deploys" -a "test" -d "Run deploys test suite"

    # docs subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from docs" -a "check" -d "Report stale sections"
    complete -c $cmd -n "__fish_seen_subcommand_from docs" -a "sync" -d "Regenerate stale sections"
    complete -c $cmd -n "__fish_seen_subcommand_from docs" -a "wiki" -d "Generate wiki pages"
    complete -c $cmd -n "__fish_seen_subcommand_from docs" -a "report" -d "Show freshness report"
    complete -c $cmd -n "__fish_seen_subcommand_from docs" -a "test" -d "Run docs test suite"

    # tmux subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from tmux" -a "doctor" -d "Check Claude compat"
    complete -c $cmd -n "__fish_seen_subcommand_from tmux" -a "install" -d "Install TPM"
    complete -c $cmd -n "__fish_seen_subcommand_from tmux" -a "fix" -d "Auto-fix issues"
    complete -c $cmd -n "__fish_seen_subcommand_from tmux" -a "reload" -d "Reload config"
    complete -c $cmd -n "__fish_seen_subcommand_from tmux" -a "test" -d "Run tmux test suite"

    # decompose subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from decompose" -a "analyze" -d "Analyze complexity"
    complete -c $cmd -n "__fish_seen_subcommand_from decompose" -a "create-subtasks" -d "Create subtasks"

    # pr subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from pr" -a "review" -d "Auto-review PR"
    complete -c $cmd -n "__fish_seen_subcommand_from pr" -a "merge" -d "Auto-merge PR"
    complete -c $cmd -n "__fish_seen_subcommand_from pr" -a "cleanup" -d "Cleanup merged branches"
    complete -c $cmd -n "__fish_seen_subcommand_from pr" -a "feedback" -d "Get PR feedback"

    # db subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from db" -a "init" -d "Initialize database"
    complete -c $cmd -n "__fish_seen_subcommand_from db" -a "health" -d "Check database health"
    complete -c $cmd -n "__fish_seen_subcommand_from db" -a "migrate" -d "Run migrations"
    complete -c $cmd -n "__fish_seen_subcommand_from db" -a "stats" -d "Show statistics"
    complete -c $cmd -n "__fish_seen_subcommand_from db" -a "export" -d "Export data"

    # version subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from version" -a "show" -d "Show current version"
    complete -c $cmd -n "__fish_seen_subcommand_from version" -a "bump" -d "Bump version everywhere"
    complete -c $cmd -n "__fish_seen_subcommand_from version" -a "check" -d "Verify version consistency"

    # evidence subcommands
    complete -c $cmd -n "__fish_seen_subcommand_from evidence" -a "capture" -d "Capture evidence artifacts"
    complete -c $cmd -n "__fish_seen_subcommand_from evidence" -a "verify" -d "Verify evidence freshness"
    complete -c $cmd -n "__fish_seen_subcommand_from evidence" -a "pre-pr" -d "Run pre-PR evidence checks"

    # ═══════════════════════════════════════════════════════════════════════
    # FLAGS
    # ═══════════════════════════════════════════════════════════════════════

    # pipeline flags
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l issue -d "GitHub issue number" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l goal -d "Goal description" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l repo -d "Change to directory before running" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l local -d "Local-only mode (no GitHub)"
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l pipeline -d "Pipeline template" -r
    complete -c $cmd -n "__fish_seen_subcommand_from pipeline" -l template -d "Pipeline template" -ra "fast standard full hotfix autonomous enterprise cost-aware deployed"
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

    # cost flags
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -l period -d "Number of days to report" -r
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -l json -d "JSON output"
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -l by-stage -d "Breakdown by pipeline stage"
    complete -c $cmd -n "__fish_seen_subcommand_from cost" -l by-issue -d "Breakdown by issue"

    # prep flags
    complete -c $cmd -n "__fish_seen_subcommand_from prep" -l check -d "Audit existing prep quality"
    complete -c $cmd -n "__fish_seen_subcommand_from prep" -l with-claude -d "Deep analysis using Claude Code"
    complete -c $cmd -n "__fish_seen_subcommand_from prep" -l verbose -d "Verbose output"

    # fix flags
    complete -c $cmd -n "__fish_seen_subcommand_from fix" -l repos -d "Repository paths" -r
    complete -c $cmd -n "__fish_seen_subcommand_from fix" -l worktree -d "Use git worktrees"
    complete -c $cmd -n "__fish_seen_subcommand_from fix" -l test-cmd -d "Test command" -r

    # logs flags
    complete -c $cmd -n "__fish_seen_subcommand_from logs" -l follow -d "Tail logs in real time"
    complete -c $cmd -n "__fish_seen_subcommand_from logs" -l lines -d "Number of lines to show" -r

    # cleanup flags
    complete -c $cmd -n "__fish_seen_subcommand_from cleanup" -l force -d "Actually kill orphaned sessions"

    # upgrade flags
    complete -c $cmd -n "__fish_seen_subcommand_from upgrade" -l apply -d "Apply available updates"

    # reaper flags
    complete -c $cmd -n "__fish_seen_subcommand_from reaper" -l watch -d "Continuous watch mode"

    # status flags
    complete -c $cmd -n "__fish_seen_subcommand_from status" -l json -d "JSON output"

    # doctor flags
    complete -c $cmd -n "__fish_seen_subcommand_from doctor" -l json -d "JSON output"

    # daemon flags
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -l detach -d "Run in background tmux session"
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -l no-github -d "Local mode"
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -l max-parallel -d "Max parallel workers" -r
    complete -c $cmd -n "__fish_seen_subcommand_from daemon" -l auto-scale -d "Enable auto-scaling"

    # session flags
    complete -c $cmd -n "__fish_seen_subcommand_from session" -l template -d "Team template" -r
    complete -c $cmd -n "__fish_seen_subcommand_from session" -s t -d "Team template" -r
    complete -c $cmd -n "__fish_seen_subcommand_from session" -l agents -d "Number of agents" -r
    complete -c $cmd -n "__fish_seen_subcommand_from session" -l roles -d "Agent roles" -r

    # remote flags
    complete -c $cmd -n "__fish_seen_subcommand_from remote" -l host -d "Hostname" -r
    complete -c $cmd -n "__fish_seen_subcommand_from remote" -l port -d "SSH port" -r
    complete -c $cmd -n "__fish_seen_subcommand_from remote" -l key -d "SSH key" -rF
    complete -c $cmd -n "__fish_seen_subcommand_from remote" -l user -d "SSH user" -r

    # connect flags
    complete -c $cmd -n "__fish_seen_subcommand_from connect" -l token-file -d "File holding the invite token" -r -F

    # fleet flags
    complete -c $cmd -n "__fish_seen_subcommand_from fleet" -l org -d "GitHub organization" -r
    complete -c $cmd -n "__fish_seen_subcommand_from fleet" -l language -d "Filter by language" -r
    complete -c $cmd -n "__fish_seen_subcommand_from fleet" -l config -d "Fleet config file" -rF

    # help flags
    complete -c $cmd -n "__fish_seen_subcommand_from help" -l all -d "Show all commands"
    complete -c $cmd -n "__fish_seen_subcommand_from help" -s a -d "Show all commands"
end
