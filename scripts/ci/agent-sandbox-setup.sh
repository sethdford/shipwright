#!/usr/bin/env bash
# CI: install the agent sandbox dependencies on a Linux runner (#8614). Mirrors the Ubuntu 24.04 setup in
# the Claude sandbox docs: bubblewrap + socat, and user namespaces allowed when the kernel restricts
# them. Ends with the same check agent-exec relies on, so a runner that still
# cannot sandbox fails here, loudly, and not as an authentication error later.
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "agent-sandbox-setup: not Linux, nothing to install"
    exit 0
fi

if ! command -v bwrap >/dev/null 2>&1 || ! command -v socat >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y bubblewrap socat
fi

# Ubuntu 24.04 restricts unprivileged user namespaces through AppArmor. A profile for /usr/bin/bwrap lets
# bwrap start, but the CLI's seccomp helper then creates a nested namespace inside it and loses the
# capability to write /proc/self/setgroups, so every agent Bash call failed. The runner is a disposable
# VM and bwrap plus seccomp still confine the agent, so lift the restriction for the job.
for knob in kernel.apparmor_restrict_unprivileged_userns kernel.apparmor_restrict_unprivileged_unconfined; do
    if [[ "$(sysctl -n "$knob" 2>/dev/null || echo none)" == "1" ]]; then
        sudo sysctl -w "$knob=0"
    fi
done

bash "$(dirname "${BASH_SOURCE[0]}")/../lib/agent-sandbox.sh" check
echo "agent-sandbox-setup: sandbox ready"
