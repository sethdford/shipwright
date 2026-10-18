#!/usr/bin/env bash
# lib/agent-sandbox.sh — checks that the agent sandbox can start (#8614).
#
# config/agent-permissions.json sets sandbox.failIfUnavailable, so the Claude CLI exits at startup when
# its sandbox dependencies are missing. On Linux those are bubblewrap (bwrap) and socat, and on Ubuntu
# 24.04+ bwrap also needs an AppArmor profile that allows user namespaces. This check reports the missing
# piece with the fix, so a failure is never mistaken for an authentication problem.
#
#   source lib/agent-sandbox.sh && sw_agent_sandbox_check   # returns 0 when ready, 1 with a message on stderr
#   scripts/lib/agent-sandbox.sh check                       # the same, as a command
# No `set` here: this file is sourced by sw-doctor and must not change its caller's shell options.

sw_agent_sandbox_check() {
    case "$(uname -s)" in
        Darwin) return 0 ;;   # sandbox-exec ships with macOS
        Linux) ;;
        *)
            echo "agent sandbox: unsupported platform $(uname -s). Agents need macOS, Linux or WSL2." >&2
            return 1 ;;
    esac
    local missing=""
    command -v bwrap >/dev/null 2>&1 || missing="${missing} bubblewrap"
    command -v socat >/dev/null 2>&1 || missing="${missing} socat"
    if [[ -n "$missing" ]]; then
        echo "agent sandbox: missing${missing}. Install: sudo apt-get install -y bubblewrap socat (Fedora: sudo dnf install bubblewrap socat)." >&2
        echo "agent sandbox: agents refuse to run without the sandbox (sandbox.failIfUnavailable), so nothing will run until it is installed." >&2
        return 1
    fi
    if ! bwrap --ro-bind / / true >/dev/null 2>&1; then
        echo "agent sandbox: bwrap cannot create user namespaces. On Ubuntu 24.04+ add the AppArmor profile for /usr/bin/bwrap" >&2
        echo "agent sandbox: (see scripts/ci/agent-sandbox-setup.sh), then run: sudo systemctl reload apparmor" >&2
        return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-check}" in
        check) sw_agent_sandbox_check ;;
        *) echo "usage: agent-sandbox.sh check" >&2; exit 2 ;;
    esac
fi
