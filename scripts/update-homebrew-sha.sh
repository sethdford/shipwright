#!/usr/bin/env bash
# Updates homebrew/shipwright.rb with SHA256 hashes from the release artifacts.
# Downloads each tarball, computes SHA256, and updates the formula in-place.
#
# Usage: scripts/update-homebrew-sha.sh <version-tag>
#   Example: scripts/update-homebrew-sha.sh v0.4.2
#
# Run after release artifacts are uploaded to GitHub Releases.
set -euo pipefail

VERSION="3.0.0"
VERSION_NUM="${VERSION#v}"
REPO="${SHIPWRIGHT_GITHUB_REPO:-sethdford/shipwright}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMULA="${REPO_ROOT}/homebrew/shipwright.rb"
BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"

TMPDIR="${TMPDIR:-/tmp}/shipwright-sha-$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

# Download each artifact and compute SHA256
sha_darwin_arm64=""
sha_darwin_x86_64=""
sha_linux_x86_64=""

for platform in darwin-arm64 darwin-x86_64 linux-x86_64; do
  filename="shipwright-${platform}.tar.gz"
  url="${BASE_URL}/${filename}"
  dest="${TMPDIR}/${filename}"
  echo "Downloading ${url}..."
  if ! curl -sfL -o "$dest" "$url"; then
    echo "ERROR: Failed to download $url" >&2
    exit 1
  fi
  if command -v shasum >/dev/null 2>&1; then
    sha=$(shasum -a 256 "$dest" | awk '{print $1}')
  else
    sha=$(sha256sum "$dest" | awk '{print $1}')
  fi
  case "$platform" in
    darwin-arm64)   sha_darwin_arm64="$sha" ;;
    darwin-x86_64)  sha_darwin_x86_64="$sha" ;;
    linux-x86_64)   sha_linux_x86_64="$sha" ;;
  esac
  echo "  ${platform}: ${sha}"
done

# Update formula: version and SHA256 values
# sed -i '' on macOS, sed -i on Linux
if [[ "$(uname -s)" == "Darwin" ]]; then
  sed -i '' "s|version \"[^\"]*\"|version \"${VERSION_NUM}\"|g" "$FORMULA"
  sed -i '' "s|sha256 \"PLACEHOLDER_DARWIN_ARM64_SHA256\"|sha256 \"${sha_darwin_arm64}\"|g" "$FORMULA"
  sed -i '' "s|sha256 \"PLACEHOLDER_DARWIN_X86_64_SHA256\"|sha256 \"${sha_darwin_x86_64}\"|g" "$FORMULA"
  sed -i '' "s|sha256 \"PLACEHOLDER_LINUX_X86_64_SHA256\"|sha256 \"${sha_linux_x86_64}\"|g" "$FORMULA"
else
  sed -i "s|version \"[^\"]*\"|version \"${VERSION_NUM}\"|g" "$FORMULA"
  sed -i "s|sha256 \"PLACEHOLDER_DARWIN_ARM64_SHA256\"|sha256 \"${sha_darwin_arm64}\"|g" "$FORMULA"
  sed -i "s|sha256 \"PLACEHOLDER_DARWIN_X86_64_SHA256\"|sha256 \"${sha_darwin_x86_64}\"|g" "$FORMULA"
  sed -i "s|sha256 \"PLACEHOLDER_LINUX_X86_64_SHA256\"|sha256 \"${sha_linux_x86_64}\"|g" "$FORMULA"
fi

echo ""
echo "Updated $FORMULA for v${VERSION_NUM}:"
echo "  darwin-arm64:   ${sha_darwin_arm64}"
echo "  darwin-x86_64:  ${sha_darwin_x86_64}"
echo "  linux-x86_64:   ${sha_linux_x86_64}"
