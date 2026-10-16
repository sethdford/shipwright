#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Bash tab completions                                      ║
# ║  Auto-install to ~/.local/share/bash-completion/completions/ during init║
# ╚═══════════════════════════════════════════════════════════════════════════╝

_shipwright_completions() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Top-level commands — all 90+ from the CLI router
    local commands="agent quality observe release intel session status mission-control ps logs activity templates doctor cleanup reaper upgrade loop pipeline worktree prep hygiene daemon autonomous memory guild instrument cost adaptive regression incident db deps fleet fleet-viz fix init setup dashboard public-dashboard jira linear model tracker heartbeat standup checkpoint durable webhook connect remote launchd auth intelligence optimize predict adversarial simulation strategic architecture vitals stream docs changelog docs-agent doc-fleet release-manager replay review-rerun scale swarm dora retro tmux tmux-pipeline github checks ci deploys github-app decompose discovery context trace pr widgets feedback eventbus evidence otel triage pipeline-composer oversight code-review pm team-stages ux recruit testgen e2e security-audit help version"

    case "$prev" in
        shipwright|sw)
            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
            return 0
            ;;
        # ─── Group routers ────────────────────────────────────────────────
        agent)
            COMPREPLY=( $(compgen -W "recruit swarm standup guild oversight help" -- "$cur") )
            return 0
            ;;
        quality)
            COMPREPLY=( $(compgen -W "code-review security-audit testgen hygiene validate gate help" -- "$cur") )
            return 0
            ;;
        observe)
            COMPREPLY=( $(compgen -W "vitals dora retro stream activity replay status help" -- "$cur") )
            return 0
            ;;
        release)
            COMPREPLY=( $(compgen -W "release release-manager changelog deploy build help" -- "$cur") )
            return 0
            ;;
        intel)
            COMPREPLY=( $(compgen -W "predict intelligence strategic optimize help" -- "$cur") )
            return 0
            ;;
        # ─── Subcommands for flat commands ────────────────────────────────
        pipeline)
            COMPREPLY=( $(compgen -W "start resume status abort list show test" -- "$cur") )
            return 0
            ;;
        daemon)
            COMPREPLY=( $(compgen -W "start stop status metrics triage patrol test logs init" -- "$cur") )
            return 0
            ;;
        fleet)
            COMPREPLY=( $(compgen -W "start stop status metrics discover test" -- "$cur") )
            return 0
            ;;
        memory)
            COMPREPLY=( $(compgen -W "show search forget export import stats test" -- "$cur") )
            return 0
            ;;
        cost)
            COMPREPLY=( $(compgen -W "show budget record calculate check-budget remaining-budget" -- "$cur") )
            return 0
            ;;
        templates)
            COMPREPLY=( $(compgen -W "list show" -- "$cur") )
            return 0
            ;;
        worktree)
            COMPREPLY=( $(compgen -W "create list remove" -- "$cur") )
            return 0
            ;;
        tracker)
            COMPREPLY=( $(compgen -W "init status sync test" -- "$cur") )
            return 0
            ;;
        heartbeat)
            COMPREPLY=( $(compgen -W "write check list clear" -- "$cur") )
            return 0
            ;;
        checkpoint)
            COMPREPLY=( $(compgen -W "save restore list delete" -- "$cur") )
            return 0
            ;;
        connect)
            COMPREPLY=( $(compgen -W "start stop join status" -- "$cur") )
            return 0
            ;;
        remote)
            COMPREPLY=( $(compgen -W "list add remove status test" -- "$cur") )
            return 0
            ;;
        launchd)
            COMPREPLY=( $(compgen -W "install uninstall status test" -- "$cur") )
            return 0
            ;;
        dashboard)
            COMPREPLY=( $(compgen -W "start stop status" -- "$cur") )
            return 0
            ;;
        github)
            COMPREPLY=( $(compgen -W "context security blame" -- "$cur") )
            return 0
            ;;
        checks)
            COMPREPLY=( $(compgen -W "list status test" -- "$cur") )
            return 0
            ;;
        deploys)
            COMPREPLY=( $(compgen -W "list status test" -- "$cur") )
            return 0
            ;;
        docs)
            COMPREPLY=( $(compgen -W "check sync wiki report test" -- "$cur") )
            return 0
            ;;
        tmux)
            COMPREPLY=( $(compgen -W "doctor install fix reload test" -- "$cur") )
            return 0
            ;;
        decompose)
            COMPREPLY=( $(compgen -W "analyze create-subtasks" -- "$cur") )
            return 0
            ;;
        pr)
            COMPREPLY=( $(compgen -W "review merge cleanup feedback" -- "$cur") )
            return 0
            ;;
        db)
            COMPREPLY=( $(compgen -W "init health migrate stats query export" -- "$cur") )
            return 0
            ;;
        ci)
            COMPREPLY=( $(compgen -W "generate status test" -- "$cur") )
            return 0
            ;;
        auth)
            COMPREPLY=( $(compgen -W "login logout status test" -- "$cur") )
            return 0
            ;;
        autonomous)
            COMPREPLY=( $(compgen -W "start status test" -- "$cur") )
            return 0
            ;;
        version)
            COMPREPLY=( $(compgen -W "show bump check" -- "$cur") )
            return 0
            ;;
        jira)
            COMPREPLY=( $(compgen -W "sync status test" -- "$cur") )
            return 0
            ;;
        linear)
            COMPREPLY=( $(compgen -W "sync status test" -- "$cur") )
            return 0
            ;;
        eventbus)
            COMPREPLY=( $(compgen -W "emit listen status test" -- "$cur") )
            return 0
            ;;
        evidence)
            COMPREPLY=( $(compgen -W "capture verify pre-pr" -- "$cur") )
            return 0
            ;;
        webhook)
            COMPREPLY=( $(compgen -W "start stop status test" -- "$cur") )
            return 0
            ;;
    esac

    # Flags for subcommands
    if [[ "$cur" == -* ]]; then
        case "${COMP_WORDS[1]}" in
            pipeline)
                COMPREPLY=( $(compgen -W "--issue --goal --repo --local --worktree --template --skip-gates --test-cmd --model --agents --base --reviewers --labels --no-github --no-github-label --ci --ignore-budget --dry-run --slack-webhook --self-heal --max-iterations --max-restarts --fast-test-cmd --completed-stages" -- "$cur") )
                ;;
            prep)
                COMPREPLY=( $(compgen -W "--check --with-claude --verbose" -- "$cur") )
                ;;
            loop)
                COMPREPLY=( $(compgen -W "--repo --local --test-cmd --fast-test-cmd --fast-test-interval --max-iterations --model --agents --roles --worktree --skip-permissions --max-turns --resume --max-restarts --verbose --audit --audit-agent --quality-gates --definition-of-done --no-auto-extend --extension-size --max-extensions" -- "$cur") )
                ;;
            fix)
                COMPREPLY=( $(compgen -W "--repos --worktree --test-cmd" -- "$cur") )
                ;;
            logs)
                COMPREPLY=( $(compgen -W "--follow --lines --grep" -- "$cur") )
                ;;
            cleanup)
                COMPREPLY=( $(compgen -W "--force" -- "$cur") )
                ;;
            upgrade)
                COMPREPLY=( $(compgen -W "--apply" -- "$cur") )
                ;;
            reaper)
                COMPREPLY=( $(compgen -W "--watch" -- "$cur") )
                ;;
            status)
                COMPREPLY=( $(compgen -W "--json" -- "$cur") )
                ;;
            doctor)
                COMPREPLY=( $(compgen -W "--json" -- "$cur") )
                ;;
            remote)
                COMPREPLY=( $(compgen -W "--host --port --key --user" -- "$cur") )
                ;;
            connect)
                COMPREPLY=( $(compgen -W "--url --token-file" -- "$cur") )
                ;;
            cost)
                COMPREPLY=( $(compgen -W "--period --json --by-stage --by-issue" -- "$cur") )
                ;;
            daemon)
                COMPREPLY=( $(compgen -W "--detach --no-github --max-parallel --auto-scale" -- "$cur") )
                ;;
            session)
                COMPREPLY=( $(compgen -W "--template -t --agents --roles" -- "$cur") )
                ;;
            fleet)
                COMPREPLY=( $(compgen -W "--org --language --config" -- "$cur") )
                ;;
            help)
                COMPREPLY=( $(compgen -W "--all -a" -- "$cur") )
                ;;
        esac
        return 0
    fi

    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
}

complete -F _shipwright_completions shipwright
complete -F _shipwright_completions sw
