#!/usr/bin/env bash
# CI: install the agent sandbox dependencies on a Linux runner (#8614). Mirrors the Ubuntu 24.04 setup in
# the Claude sandbox docs: bubblewrap + socat, and an AppArmor profile when the kernel restricts
# unprivileged user namespaces. Ends with the same check agent-exec relies on, so a runner that still
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

restrict="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo none)"
if [[ "$restrict" == "1" ]]; then
    sudo tee /etc/apparmor.d/bwrap > /dev/null <<'APPARMOR'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
APPARMOR
    sudo systemctl reload apparmor
fi

bash "$(dirname "${BASH_SOURCE[0]}")/../lib/agent-sandbox.sh" check
echo "agent-sandbox-setup: sandbox ready"
