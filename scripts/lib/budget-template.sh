#!/bin/bash
# Budget-aware pipeline template selection library
# Provides functions to read budget and downgrade templates when budget is low
# VERSION:1.0.0

set -euo pipefail

# Source guard
if [[ "${_BUDGET_TEMPLATE_LOADED:-}" == "1" ]]; then
  return 0
fi
_BUDGET_TEMPLATE_LOADED=1

# Fallback stubs for standalone sourcing (tests override these)
if ! declare -f emit_event >/dev/null 2>&1; then
  emit_event() { :; }
fi

if ! declare -f warn >/dev/null 2>&1; then
  warn() { echo "⚠ $*" >&2; }
fi

if ! declare -f _smart_int >/dev/null 2>&1; then
  _smart_int() {
    local key="$1" default="${2:-0}"
    # Simple fallback: check env, then return default
    local var="SW_${key^^}"
    var="${!var:-}"
    echo "${var:-$default}"
  }
fi

# budget_remaining_usd: Query the cost backend and return remaining budget
# Output: exactly one of {numeric, "unlimited", "unknown"}
# Always returns 0 (fail-open)
budget_remaining_usd() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # Try to source the cost script; fail-open if missing
  if [[ ! -f "$script_dir/sw-cost.sh" ]]; then
    echo "unknown" >&2
    return 0
  fi

  # Call sw-cost.sh remaining-budget; last line is the value
  local remaining
  remaining="$(bash "$script_dir/sw-cost.sh" remaining-budget 2>/dev/null | tail -1)" || {
    echo "unknown" >&2
    return 0
  }

  # Validate that it's numeric, "unlimited", or handle gracefully
  if [[ "$remaining" == "unlimited" ]]; then
    echo "unlimited"
    return 0
  fi

  # Check if it looks numeric (optional sign, digits, optional decimal)
  if [[ "$remaining" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    echo "$remaining"
    return 0
  fi

  # Non-numeric: fail-open
  echo "unknown" >&2
  return 0
}

# budget_template_downgrade: Return the next-lower-tier template
# Input: template name
# Output: template name (same or downgraded)
# Bash 3.2 safe: uses case statement
budget_template_downgrade() {
  local template="$1"

  case "$template" in
    enterprise|full|deployed|autonomous)
      echo "standard"
      ;;
    standard|tdd|cost-aware)
      echo "fast"
      ;;
    fast|hotfix|composed)
      # Already at floor
      echo "$template"
      ;;
    *)
      # Unknown template: pass through
      echo "$template"
      ;;
  esac
}

# budget_select_template: Main entry point
# Reads config + budget, applies downgrade logic, emits event if downgraded
# Signature: budget_select_template <template> <explicit:true|false> <source:pipeline|daemon>
# Output: final template name (stdout, single line)
# Side effects: may emit event to stderr, write to events.jsonl
# Always returns 0 (fail-open)
budget_select_template() {
  local template="${1:-standard}" explicit="${2:-false}" source="${3:-pipeline}"

  # If explicit (--template flag was used), never downgrade
  if [[ "$explicit" == "true" ]]; then
    echo "$template"
    return 0
  fi

  # Read config: enabled flag and threshold
  local enabled threshold
  enabled="$(_smart_int budget.template_downgrade_enabled true 2>/dev/null)" || enabled="true"
  threshold="$(_smart_int budget.template_downgrade_threshold_usd 10 2>/dev/null)" || threshold="10"

  # Validate threshold (must be numeric)
  if ! [[ "$threshold" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    warn "budget.template_downgrade_threshold_usd is not numeric ('$threshold'), using default 10"
    threshold="10"
  fi

  # Kill switch: if downgrade is disabled, return template unchanged
  if [[ "$enabled" != "true" ]]; then
    echo "$template"
    return 0
  fi

  # Read remaining budget
  local remaining
  remaining="$(budget_remaining_usd 2>/dev/null)" || remaining="unknown"

  # If budget is unknown or unlimited, don't downgrade
  if [[ "$remaining" == "unknown" || "$remaining" == "unlimited" ]]; then
    echo "$template"
    return 0
  fi

  # Check if remaining budget is below threshold
  # Use awk for robust numeric comparison (handles floats)
  if ! awk -v r="$remaining" -v t="$threshold" 'BEGIN{exit !(r < t)}'; then
    # Budget is sufficient; no downgrade needed
    echo "$template"
    return 0
  fi

  # Budget is low; check if template is already at floor (fast/hotfix/composed)
  local downgraded
  downgraded="$(budget_template_downgrade "$template")"

  if [[ "$downgraded" == "$template" ]]; then
    # Template already at floor; can't downgrade further
    echo "$template"
    return 0
  fi

  # Downgrade: emit event and log warning
  emit_event "pipeline.template_budget_downgrade" \
    "from=$template" "to=$downgraded" "remaining=$remaining" \
    "threshold=$threshold" "source=$source" 2>/dev/null || true

  warn "Budget low (\$$remaining < \$$threshold): downgrading template $template → $downgraded (use --template to override)"

  echo "$downgraded"
  return 0
}
