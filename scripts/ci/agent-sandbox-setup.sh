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

# TEMP-DIAG
uname -r; cat /etc/os-release | head -2; bwrap --version
echo "a:"; unshare -U -r true && echo ok
echo "b:"; bwrap --ro-bind / / --dev /dev --proc /proc -- unshare -U -r true && echo ok
echo "c:"; bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user -- unshare -U -r true && echo ok
echo "d:"; bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user -- unshare -U true && echo ok
echo "e:"; bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user --cap-add CAP_SYS_ADMIN -- unshare -U -r true && echo ok
sudo dmesg 2>/dev/null | grep -i -E "apparmor|denied" | tail -n 8 || true
aa-status 2>/dev/null | head -5 || true
# END-TEMP-DIAG
bash "$(dirname "${BASH_SOURCE[0]}")/../lib/agent-sandbox.sh" check
echo "agent-sandbox-setup: sandbox ready"
