#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  lib/quality-profile.sh — Quality Profile Management                     ║
# ║  Load, validate, and manage project quality standards (quality-profile.json) ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Source guard — prevent double-loading
[[ -n "${_QUALITY_PROFILE_LOADED:-}" ]] && return 0
_QUALITY_PROFILE_LOADED=1

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
QUALITY_PROFILE_PATH="${REPO_ROOT}/.claude/quality-profile.json"

# Default schema version
QP_SCHEMA_VERSION=1

# Cache the loaded profile (Bash 3.2 compatible — no declare -g)
_QP_CACHE=""
_QP_LOADED=0

# ─────────────────────────────────────────────────────────────────────────────
# load_quality_profile
# Load quality profile from .claude/quality-profile.json or create defaults
# Returns 0 on success, 1 on validation failure
# ─────────────────────────────────────────────────────────────────────────────
load_quality_profile() {
    # Return cached copy if already loaded
    if [[ "$_QP_LOADED" == "1" ]] && [[ -n "$_QP_CACHE" ]]; then
        echo "$_QP_CACHE"
        return 0
    fi

    if [[ -f "$QUALITY_PROFILE_PATH" ]]; then
        _QP_CACHE=$(cat "$QUALITY_PROFILE_PATH")
    else
        # Generate default profile
        _QP_CACHE=$(generate_default_profile)
    fi

    # Validate the profile
    if ! validate_quality_profile "$_QP_CACHE"; then
        return 1
    fi

    _QP_LOADED=1
    echo "$_QP_CACHE"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# validate_quality_profile <profile_json>
# Validate profile against schema (version, required fields)
# Returns 0 if valid, 1 if invalid
# ─────────────────────────────────────────────────────────────────────────────
validate_quality_profile() {
    local profile_json="$1"

    # Check if it's valid JSON
    if ! echo "$profile_json" | jq empty 2>/dev/null; then
        return 1
    fi

    # Check version field
    local version
    version=$(echo "$profile_json" | jq -r '.version // ""' 2>/dev/null)
    if [[ "$version" != "$QP_SCHEMA_VERSION" ]]; then
        return 1
    fi

    # Check required top-level fields
    local required_fields=("architecture" "testing" "quality" "review" "scope" "deployment")
    for field in "${required_fields[@]}"; do
        local value
        value=$(echo "$profile_json" | jq -r ".${field} // \"\"" 2>/dev/null)
        if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
            return 1
        fi
    done

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# qp_get <jq_path> [default]
# Get a specific value from the profile with optional default
# Usage: qp_get ".quality.max_pr_lines" "500"
# ─────────────────────────────────────────────────────────────────────────────
qp_get() {
    local jq_path="$1"
    local default="${2:-}"

    local profile
    profile=$(load_quality_profile) || return 1

    local value
    value=$(echo "$profile" | jq -r "${jq_path} // \"\"" 2>/dev/null || echo "")

    if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# qp_get_array <jq_path>
# Get array values as newline-separated list
# Usage: qp_get_array ".quality.never_ship"
# ─────────────────────────────────────────────────────────────────────────────
qp_get_array() {
    local jq_path="$1"

    local profile
    profile=$(load_quality_profile) || return 1

    # Convert array to newline-separated strings
    echo "$profile" | jq -r "${jq_path}[]? // empty" 2>/dev/null || return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# qp_add_learned_rule <rule> <source> <confidence> <inject_at_stages>
# Add a learned quality rule from outcome feedback
# Usage: qp_add_learned_rule "Always validate input" "3 PRs got review comments" 0.85 "plan,build,review"
# ─────────────────────────────────────────────────────────────────────────────
qp_add_learned_rule() {
    local rule="$1"
    local source="$2"
    local confidence="$3"
    local inject_at="$4"

    if [[ ! -f "$QUALITY_PROFILE_PATH" ]]; then
        return 1
    fi

    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Convert inject_at comma-separated to array
    local inject_array
    inject_array=$(echo "$inject_at" | jq -R 'split(",") | map(ltrimstr(" ") | rtrimstr(" "))')

    # Build the new rule as JSON object
    local new_rule
    new_rule=$(jq -n \
        --arg r "$rule" \
        --arg s "$source" \
        --arg c "$confidence" \
        --argjson i "$inject_array" \
        --arg dt "$created_at" \
        '{rule: $r, source: $s, confidence: $c, inject_at: $i, created_at: $dt}')

    # Atomic write: read, modify, write
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'; trap - RETURN" RETURN

    # Add rule to learned_rules array
    if ! jq ".quality.learned_rules += [$new_rule]" "$QUALITY_PROFILE_PATH" > "$tmp_file" 2>/dev/null; then
        return 1
    fi

    mv "$tmp_file" "$QUALITY_PROFILE_PATH"
    _QP_LOADED=0  # Invalidate cache
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# qp_get_rules_for_stage <stage_name>
# Get all learned rules for a specific stage (plan, build, review, etc)
# Usage: qp_get_rules_for_stage "build"
# ─────────────────────────────────────────────────────────────────────────────
qp_get_rules_for_stage() {
    local stage="$1"

    local profile
    profile=$(load_quality_profile) || return 1

    # Filter rules where inject_at contains the stage
    echo "$profile" | jq -r ".quality.learned_rules[]? | select(.inject_at[]? == \"$stage\") | .rule" 2>/dev/null || return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# generate_default_profile
# Generate a minimal default quality profile (non-interactive)
# Returns the profile JSON to stdout
# ─────────────────────────────────────────────────────────────────────────────
generate_default_profile() {
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local project_name
    project_name=$(basename "$REPO_ROOT")

    cat <<EOF
{
  "version": $QP_SCHEMA_VERSION,
  "project_name": "$project_name",
  "generated_at": "$now",
  "architecture": {
    "pattern": "monolith",
    "layers": [],
    "dependency_direction": "none",
    "rules": []
  },
  "testing": {
    "philosophy": "test_after",
    "min_coverage_delta": 0,
    "required_test_types": ["unit"],
    "test_cmd": "",
    "fast_test_cmd": ""
  },
  "quality": {
    "max_pr_lines": 500,
    "max_files_per_pr": 15,
    "never_ship": [],
    "always_require": [],
    "learned_rules": []
  },
  "review": {
    "focus_areas": [],
    "blocking_severities": ["critical", "bug", "security"],
    "min_issues_to_find": 3
  },
  "scope": {
    "unplanned_files_block": false,
    "decomposition_threshold_lines": 500
  },
  "deployment": {
    "strategy": "direct",
    "rollback_plan": "revert_commit",
    "monitoring_window_minutes": 30
  }
}
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# qp_save <profile_json>
# Save a quality profile to disk (atomic write)
# ─────────────────────────────────────────────────────────────────────────────
qp_save() {
    local profile_json="$1"

    # Validate before saving
    if ! validate_quality_profile "$profile_json"; then
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'; trap - RETURN" RETURN

    # Pretty-print and write atomically
    if ! echo "$profile_json" | jq '.' > "$tmp_file" 2>/dev/null; then
        return 1
    fi

    mkdir -p "$(dirname "$QUALITY_PROFILE_PATH")"
    mv "$tmp_file" "$QUALITY_PROFILE_PATH"
    _QP_LOADED=0  # Invalidate cache
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# qp_merge <base_profile> <updates>
# Deep merge two profile objects (updates override base)
# ─────────────────────────────────────────────────────────────────────────────
qp_merge() {
    local base="$1"
    local updates="$2"

    # Use jq's * operator for recursive merge
    echo "$base" | jq --argjson u "$updates" '. * $u' 2>/dev/null || return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# qp_infer_from_repo
# Analyze the repo to infer quality profile settings
# Returns JSON with inferred values
# ─────────────────────────────────────────────────────────────────────────────
qp_infer_from_repo() {
    local test_cmd=""
    local fast_test_cmd=""
    local philosophy="test_after"
    local framework="monolith"

    # Infer test command from package.json
    if [[ -f "$REPO_ROOT/package.json" ]]; then
        if jq -e '.scripts.test' "$REPO_ROOT/package.json" >/dev/null 2>&1; then
            test_cmd="npm test"
        fi
    elif [[ -f "$REPO_ROOT/go.mod" ]]; then
        test_cmd="go test ./..."
    elif [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
        test_cmd="cargo test"
    elif [[ -f "$REPO_ROOT/pyproject.toml" ]] || [[ -f "$REPO_ROOT/setup.py" ]]; then
        test_cmd="pytest"
    fi

    # Infer architecture from repo structure
    if [[ -d "$REPO_ROOT/services" ]] || [[ -d "$REPO_ROOT/microservices" ]]; then
        framework="microservices"
    elif [[ -d "$REPO_ROOT/packages" ]] && [[ -d "$REPO_ROOT/apps" ]]; then
        framework="modular_monolith"
    fi

    # Output as JSON fragment
    jq -n \
        --arg test_cmd "$test_cmd" \
        --arg framework "$framework" \
        '{test_cmd: $test_cmd, framework: $framework}'
}

# ─────────────────────────────────────────────────────────────────────────────
# qp_get_version
# Get the schema version of the profile
# ─────────────────────────────────────────────────────────────────────────────
qp_get_version() {
    local profile
    profile=$(load_quality_profile) || return 1
    echo "$profile" | jq -r '.version // ""' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# qp_clear_cache
# Clear the in-memory cache (used before reload)
# ─────────────────────────────────────────────────────────────────────────────
qp_clear_cache() {
    _QP_CACHE=""
    _QP_LOADED=0
}
