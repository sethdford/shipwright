#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Version consistency check                                  ║
# ║  Fails if package.json version != README badge / script VERSION=          ║
# ║  Run in CI or before release to catch drift.                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CANONICAL=""
if [[ -f "$REPO_ROOT/package.json" ]]; then
  if command -v jq &>/dev/null; then
    CANONICAL="$(jq -r .version "$REPO_ROOT/package.json")"
  else
    CANONICAL="$(grep -oE '"version":\s*"[^"]+"' "$REPO_ROOT/package.json" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')"
  fi
fi

if [[ -z "$CANONICAL" ]]; then
  echo "check-version-consistency: could not read version from package.json" >&2
  exit 1
fi

ERR=0

# README badge: version-X.Y.Z and alt="vX.Y.Z"
if [[ -f "$REPO_ROOT/README.md" ]]; then
  if ! grep -q "badge/version-$CANONICAL" "$REPO_ROOT/README.md"; then
    echo "check-version-consistency: README badge version does not match package.json ($CANONICAL)" >&2
    ERR=1
  fi
  if ! grep -q "alt=\"v$CANONICAL\"" "$REPO_ROOT/README.md"; then
    echo "check-version-consistency: README alt version does not match package.json ($CANONICAL)" >&2
    ERR=1
  fi
fi

# Sample scripts: VERSION= must match (check a few key ones)
SAMPLES=(
  "$REPO_ROOT/scripts/sw"
  "$REPO_ROOT/scripts/sw-daemon.sh"
  "$REPO_ROOT/scripts/sw-pipeline.sh"
  "$REPO_ROOT/scripts/install-remote.sh"
)
for f in "${SAMPLES[@]}"; do
  if [[ -f "$f" ]]; then
    V="$(grep -m1 '^VERSION="' "$f" 2>/dev/null | sed 's/^VERSION="\([^"]*\)".*/\1/')"
    if [[ -n "$V" && "$V" != "$CANONICAL" ]]; then
      echo "check-version-consistency: $(basename "$f") has VERSION=$V, expected $CANONICAL" >&2
      ERR=1
    fi
  fi
done

# Any script under scripts/ with ^VERSION=" that differs
while IFS= read -r file; do
  V="$(grep -m1 '^VERSION="' "$file" 2>/dev/null | sed 's/^VERSION="\([^"]*\)".*/\1/')"
  if [[ -n "$V" && "$V" != "$CANONICAL" ]]; then
    echo "check-version-consistency: $(basename "$file") has VERSION=$V, expected $CANONICAL" >&2
    ERR=1
  fi
done < <(grep -rl '^VERSION="' "$REPO_ROOT/scripts/" 2>/dev/null || true)

if [[ $ERR -eq 1 ]]; then
  echo "Run: bash scripts/update-version.sh $CANONICAL" >&2
  exit 1
fi

echo "Version consistent: $CANONICAL"
exit 0
