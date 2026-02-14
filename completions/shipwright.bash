#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Bash tab completions                                      ║
# ║  Auto-install to ~/.local/share/bash-completion/completions/ during init║
# ╚═══════════════════════════════════════════════════════════════════════════╝

_shipwright_completions() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Top-level commands
    local commands="init setup session status ps logs templates doctor cleanup reaper upgrade loop pipeline worktree prep daemon fleet memory cost db fix dashboard jira linear tracker heartbeat checkpoint webhook decompose connect remote launchd intelligence optimize predict adversarial simulate architecture vitals docs tmux github checks deploys pr context help version"

    case "$prev" in
        shipwright|sw|cct)
            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
            return 0
            ;;
        pipeline)
            COMPREPLY=( $(compgen -W "start resume status test" -- "$cur") )
            return 0
            ;;
        daemon)
            COMPREPLY=( $(compgen -W "start stop status metrics test" -- "$cur") )
            return 0
            ;;
        fleet)
            COMPREPLY=( $(compgen -W "start stop status metrics test" -- "$cur") )
            return 0
            ;;
        memory)
            COMPREPLY=( $(compgen -W "show search stats" -- "$cur") )
            return 0
            ;;
        cost)
            COMPREPLY=( $(compgen -W "show budget" -- "$cur") )
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
        budget)
            COMPREPLY=( $(compgen -W "set show" -- "$cur") )
            return 0
            ;;
    esac

    # Flags for subcommands already handled above; fall back to commands
    if [[ "$cur" == -* ]]; then
        case "${COMP_WORDS[1]}" in
            pipeline)
                COMPREPLY=( $(compgen -W "--issue --goal --worktree --template --skip-gates" -- "$cur") )
                ;;
            prep)
                COMPREPLY=( $(compgen -W "--check --with-claude --verbose" -- "$cur") )
                ;;
            loop)
                COMPREPLY=( $(compgen -W "--test-cmd --max-iterations --model --agents --audit --audit-agent --quality-gates --definition-of-done --resume --skip-permissions" -- "$cur") )
                ;;
            fix)
                COMPREPLY=( $(compgen -W "--repos" -- "$cur") )
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
                COMPREPLY=( $(compgen -W "--token" -- "$cur") )
                ;;
            cost)
                COMPREPLY=( $(compgen -W "--period --json --by-stage" -- "$cur") )
                ;;
        esac
        return 0
    fi

    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
}

complete -F _shipwright_completions shipwright
complete -F _shipwright_completions sw
complete -F _shipwright_completions cct
