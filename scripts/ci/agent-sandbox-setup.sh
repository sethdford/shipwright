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

# Ubuntu restricts unprivileged user namespaces through AppArmor. Ubuntu 26.04 also ships
# bwrap-userns-restrict, which puts everything an unprivileged bwrap starts under the unpriv_bwrap profile
# and denies CAP_SYS_ADMIN in nested namespaces. The CLI's seccomp helper creates exactly such a nested
# namespace, so every agent Bash call failed ("apply-seccomp: write /proc/self/setgroups"). The runner is a
# disposable VM and bwrap plus seccomp still confine the agent, so lift both for the job.
for knob in kernel.apparmor_restrict_unprivileged_userns kernel.apparmor_restrict_unprivileged_unconfined; do
    if [[ "$(sysctl -n "$knob" 2>/dev/null || echo none)" == "1" ]]; then
        sudo sysctl -w "$knob=0"
    fi
done
bwrap_restrict=/etc/apparmor.d/bwrap-userns-restrict
if [[ -f "$bwrap_restrict" ]]; then
    sudo apparmor_parser -R "$bwrap_restrict"
    sudo ln -sf "$bwrap_restrict" /etc/apparmor.d/disable/
fi

# TEMP-DIAG
uname -r; cat /etc/os-release | head -2; bwrap --version
echo "a:"; unshare -U -r true && echo ok
echo "b:"; bwrap --ro-bind / / --dev /dev --proc /proc -- unshare -U -r true && echo ok
echo "c:"; bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user -- unshare -U -r true && echo ok
echo "d:"; bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user -- unshare -U true && echo ok
echo "e:"; bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user --cap-add CAP_SYS_ADMIN -- unshare -U -r true && echo ok
sudo dmesg 2>/dev/null | grep -i -E "apparmor|denied" | tail -n 8 || true
find /etc/apparmor.d -maxdepth 1 -iname "*bwrap*" -o -maxdepth 1 -iname "*userns*"; sudo aa-status 2>/dev/null | grep -i bwrap || true
# END-TEMP-DIAG
bash "$(dirname "${BASH_SOURCE[0]}")/../lib/agent-sandbox.sh" check
echo "agent-sandbox-setup: sandbox ready"
