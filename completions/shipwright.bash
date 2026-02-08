#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Bash tab completions                                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Source this file or place it in /usr/local/etc/bash_completion.d/

_shipwright_completions() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Top-level commands
    local commands="session status ps logs templates doctor cleanup reaper upgrade loop pipeline worktree prep daemon memory cost init help version"

    case "$prev" in
        shipwright|sw|cct)
            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
            return 0
            ;;
        pipeline)
            COMPREPLY=( $(compgen -W "start resume status abort list show test" -- "$cur") )
            return 0
            ;;
        daemon)
            COMPREPLY=( $(compgen -W "start stop status metrics triage patrol test logs init" -- "$cur") )
            return 0
            ;;
        memory)
            COMPREPLY=( $(compgen -W "show search forget export import stats test" -- "$cur") )
            return 0
            ;;
        cost)
            COMPREPLY=( $(compgen -W "show budget record calculate check-budget" -- "$cur") )
            return 0
            ;;
        templates)
            COMPREPLY=( $(compgen -W "list show" -- "$cur") )
            return 0
            ;;
        prep)
            COMPREPLY=( $(compgen -W "--check --with-claude --verbose" -- "$cur") )
            return 0
            ;;
        loop)
            COMPREPLY=( $(compgen -W "--test-cmd --max-iterations --model --agents --audit --audit-agent --quality-gates --definition-of-done --resume --skip-permissions" -- "$cur") )
            return 0
            ;;
        logs)
            COMPREPLY=( $(compgen -W "--follow --lines" -- "$cur") )
            return 0
            ;;
        cleanup)
            COMPREPLY=( $(compgen -W "--force" -- "$cur") )
            return 0
            ;;
        upgrade)
            COMPREPLY=( $(compgen -W "--apply" -- "$cur") )
            return 0
            ;;
        reaper)
            COMPREPLY=( $(compgen -W "--watch" -- "$cur") )
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
            prep)    COMPREPLY=( $(compgen -W "--check --with-claude --verbose" -- "$cur") ) ;;
            loop)    COMPREPLY=( $(compgen -W "--test-cmd --max-iterations --model --agents --audit --audit-agent --quality-gates --definition-of-done --resume --skip-permissions" -- "$cur") ) ;;
            logs)    COMPREPLY=( $(compgen -W "--follow --lines" -- "$cur") ) ;;
            cleanup) COMPREPLY=( $(compgen -W "--force" -- "$cur") ) ;;
            upgrade) COMPREPLY=( $(compgen -W "--apply" -- "$cur") ) ;;
            reaper)  COMPREPLY=( $(compgen -W "--watch" -- "$cur") ) ;;
            cost)    COMPREPLY=( $(compgen -W "--period --json --by-stage --by-issue" -- "$cur") ) ;;
        esac
        return 0
    fi

    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
}

complete -F _shipwright_completions shipwright
complete -F _shipwright_completions sw
complete -F _shipwright_completions cct
