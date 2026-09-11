#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   intent-analysis.sh — Issue intent analysis and acceptance criteria
#   Source from pipeline-stages-intake.sh. Requires helpers, artifacts.
# ═══════════════════════════════════════════════════════════════════

[[ -n "${_INTENT_ANALYSIS_LOADED:-}" ]] && return 0
_INTENT_ANALYSIS_LOADED=1

# ─── Acceptance Criteria JSON Schema ──────────────────────────────
# Each criterion has: id, description, verifiable (boolean), type
# Types: functional, nonfunctional, constraint, acceptance_test
_ACCEPTANCE_CRITERIA_SCHEMA='{
  "version": 1,
  "goal": "string",
  "generated_at": "ISO-8601",
  "who_benefits": "string",
  "what_changes": "string",
  "why_matters": "string",
  "how_know_worked": "string",
  "out_of_scope": "string",
  "criteria": [
    {
      "id": "ac-1",
      "description": "string",
      "type": "functional|nonfunctional|constraint|acceptance_test",
      "verifiable": true
    }
  ]
}'

# Analyze issue intent and generate acceptance criteria JSON
# Reads issue metadata (title, body, labels) and quality profile
# Outputs acceptance-criteria.json to artifacts dir
# Usage: analyze_intent "$title" "$body" "$labels" "$artifacts_dir"
analyze_intent() {
    local title="$1"
    local body="${2:-}"
    local labels="${3:-}"
    local artifacts_dir="${4:-.claude/pipeline-artifacts}"

    mkdir -p "$artifacts_dir" || return 1

    # Load quality profile if available for architecture context
    local quality_profile="${PROJECT_ROOT:-.}/.claude/quality-profile.json"
    local arch_context=""
    if [[ -f "$quality_profile" ]]; then
        arch_context=$(jq -r '.architecture // {}' "$quality_profile" 2>/dev/null || true)
    fi

    # Build intent analysis prompt
    local intent_prompt="Analyze this issue deeply to understand what success looks like.

## Issue Metadata
Title: ${title}
Labels: ${labels}

## Issue Description
${body}
"

    # Add architecture context if available
    if [[ -n "$arch_context" && "$arch_context" != "{}" ]]; then
        intent_prompt="${intent_prompt}
## Project Architecture
$(echo "$arch_context" | jq -c . 2>/dev/null || echo "$arch_context")
"
    fi

    intent_prompt="${intent_prompt}

## Your Analysis

Deeply analyze this issue before any implementation planning. Answer these questions:

1. **WHO benefits?** (end user / developer / ops / CI / customer)
2. **WHAT changes?** (concrete before→after behavior, with specific examples)
3. **WHY does this matter?** (pain it solves or capability it unlocks)
4. **HOW will we know it worked?** (observable signals — specific, testable, measurable)
5. **WHAT SHOULD WE NOT DO?** (explicit out-of-scope boundaries and non-goals)

## Acceptance Criteria

Generate 3-7 machine-verifiable criteria. Each criterion must:
- Be testable (not vague)
- Reference the specific change or capability
- Include how to verify it passes

Format your response as JSON matching this schema (output ONLY the JSON, no markdown):
${_ACCEPTANCE_CRITERIA_SCHEMA}
"

    # Call Claude to analyze intent
    local intent_file="${artifacts_dir}/.intent-analysis.tmp"
    if ! command -v claude >/dev/null 2>&1; then
        # Fallback: generate basic acceptance criteria without Claude
        _generate_default_acceptance_criteria "$title" "$body" "$artifacts_dir"
        return 0
    fi

    # Use Claude to analyze intent
    local _token_log="${artifacts_dir}/.claude-tokens-intent.log"
    claude --print --output-format json -p "$intent_prompt" < /dev/null > "$intent_file" 2>"$_token_log" || {
        # Fall back to defaults if Claude fails
        _generate_default_acceptance_criteria "$title" "$body" "$artifacts_dir"
        return 0
    }

    # Validate JSON output
    if ! jq empty "$intent_file" 2>/dev/null; then
        # Claude output wasn't valid JSON — generate defaults
        _generate_default_acceptance_criteria "$title" "$body" "$artifacts_dir"
        rm -f "$intent_file"
        return 0
    fi

    # `--output-format json` wraps the model's answer in a CLI envelope
    # ({type, result, usage, ...}); the criteria live in .result as text that
    # may still be fenced. Unwrap before validating, and accept a bare
    # criteria object too in case the envelope shape changes.
    local criteria_json
    criteria_json=$(_extract_acceptance_criteria "$intent_file")
    if [[ -z "$criteria_json" ]]; then
        _generate_default_acceptance_criteria "$title" "$body" "$artifacts_dir"
        rm -f "$intent_file"
        return 0
    fi

    # Move to final location atomically
    local criteria_file="${artifacts_dir}/acceptance-criteria.json"
    printf '%s\n' "$criteria_json" > "${intent_file}.out" 2>/dev/null &&
        mv "${intent_file}.out" "$criteria_file" 2>/dev/null || {
        rm -f "${intent_file}.out"
        _generate_default_acceptance_criteria "$title" "$body" "$artifacts_dir"
        rm -f "$intent_file"
        return 1
    }
    rm -f "$intent_file"

    return 0
}

# _extract_acceptance_criteria <file>
# Echoes the acceptance-criteria object from a Claude CLI response, or nothing
# if the response does not carry one. Accepts the `--output-format json`
# envelope (criteria in .result, optionally inside a ```json fence) as well as
# a bare criteria object.
_extract_acceptance_criteria() {
    local file="$1"
    local candidate

    for candidate in \
        "$(jq -r 'if (.version and .goal and (.criteria | type == "array")) then . else empty end' "$file" 2>/dev/null || true)" \
        "$(jq -r '.result // empty' "$file" 2>/dev/null | sed -e '/^[[:space:]]*```/d' || true)"
    do
        [[ -z "$candidate" ]] && continue
        if printf '%s' "$candidate" | jq -e \
            '.version and .goal and (.criteria | type == "array") and (.criteria | length > 0)' \
            >/dev/null 2>&1; then
            printf '%s' "$candidate" | jq .
            return 0
        fi
    done

    return 1
}

# Generate default acceptance criteria when Claude is unavailable
# Extracts basic requirements from title and body
_generate_default_acceptance_criteria() {
    local title="$1"
    local body="$2"
    local artifacts_dir="$3"

    # Extract key requirements from title and body
    local description="${title}"
    [[ -n "$body" ]] && description="${description} — ${body:0:200}"

    # Build minimal but valid JSON
    local json
    json=$(jq -n \
        --arg goal "$title" \
        --arg desc "$description" \
        --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")" \
        '{
          version: 1,
          goal: $goal,
          generated_at: $now,
          who_benefits: "project stakeholders",
          what_changes: $desc,
          why_matters: "addresses the issue",
          how_know_worked: "issue is resolved and verified",
          out_of_scope: "unspecified",
          criteria: [
            {
              id: "ac-1",
              description: ("Implement: " + $goal),
              type: "functional",
              verifiable: true
            },
            {
              id: "ac-2",
              description: "All tests pass",
              type: "acceptance_test",
              verifiable: true
            },
            {
              id: "ac-3",
              description: "Code is reviewed and approved",
              type: "constraint",
              verifiable: true
            }
          ]
        }')

    # Write atomically
    local criteria_file="${artifacts_dir}/acceptance-criteria.json"
    echo "$json" > "$criteria_file" 2>/dev/null || return 1
    return 0
}

# Load acceptance criteria from artifacts
# Returns the full JSON object
# Usage: load_acceptance_criteria "$artifacts_dir"
load_acceptance_criteria() {
    local artifacts_dir="${1:-.claude/pipeline-artifacts}"
    local criteria_file="${artifacts_dir}/acceptance-criteria.json"

    if [[ ! -f "$criteria_file" ]]; then
        echo "{}"
        return 0
    fi

    # Validate and return JSON
    if jq empty "$criteria_file" 2>/dev/null; then
        cat "$criteria_file"
        return 0
    fi

    # Corrupt file — return empty
    echo "{}"
    return 1
}

# Format acceptance criteria for injection into prompts
# Outputs human-readable markdown
# Usage: format_acceptance_criteria_for_prompt "$artifacts_dir"
format_acceptance_criteria_for_prompt() {
    local artifacts_dir="${1:-.claude/pipeline-artifacts}"
    local criteria_json
    criteria_json=$(load_acceptance_criteria "$artifacts_dir")

    if [[ -z "$criteria_json" || "$criteria_json" == "{}" ]]; then
        echo "No acceptance criteria defined."
        return 0
    fi

    # Extract and format criteria
    local output=""
    output+="## Definition of Success

"

    # Add who/what/why/how if present
    local who why what how
    who=$(echo "$criteria_json" | jq -r '.who_benefits // empty' 2>/dev/null || true)
    what=$(echo "$criteria_json" | jq -r '.what_changes // empty' 2>/dev/null || true)
    why=$(echo "$criteria_json" | jq -r '.why_matters // empty' 2>/dev/null || true)
    how=$(echo "$criteria_json" | jq -r '.how_know_worked // empty' 2>/dev/null || true)

    [[ -n "$who" ]] && output+="**Who benefits**: ${who}
"
    [[ -n "$what" ]] && output+="**What changes**: ${what}
"
    [[ -n "$why" ]] && output+="**Why it matters**: ${why}
"
    [[ -n "$how" ]] && output+="**How we'll know it worked**: ${how}
"

    # Add structured criteria
    output+="
### Acceptance Criteria

"
    local count=0
    local ids=""
    echo "$criteria_json" | jq -r '.criteria[]? | "\(.id)|\(.description)|\(.type)|\(.verifiable)"' 2>/dev/null | while IFS='|' read -r id desc type verifiable; do
        [[ -z "$id" ]] && continue
        count=$((count + 1))
        output+="- [\`${id}\`] ${desc} (${type}, verifiable: ${verifiable})
"
    done

    echo -n "$output"
    return 0
}

# Inject failure mode analysis requirement into plan prompt
# Uses architecture rules from quality profile
# Usage: inject_failure_mode_analysis "$plan_prompt" "$quality_profile_path"
inject_failure_mode_analysis() {
    local plan_prompt="$1"
    local quality_profile="${2:-.claude/quality-profile.json}"

    # Load architecture rules if available
    local arch_rules=""
    if [[ -f "$quality_profile" ]]; then
        arch_rules=$(jq -r '.architecture.rules[]? // empty' "$quality_profile" 2>/dev/null | sed 's/^/  - /' || true)
    fi

    # Build failure mode injection section
    local injection="
## Mandatory Failure Mode Analysis

After your implementation plan, you MUST include a section titled:

### Failure Mode Analysis

For each major component or decision in your plan:

1. **Runtime Failures**: What happens when dependencies are unavailable, network timeouts occur, or external services fail?
2. **Concurrency Risks**: Race conditions, stale state, duplicate processing, or inconsistent updates?
3. **Scale Risks**: What breaks when data grows 10x, dependencies are slow, or memory pressure increases?
4. **Rollback Story**: Can we revert this change safely? Is there data migration risk?

You MUST identify at least 3 concrete failure modes specific to this codebase and task.

"

    # Add architecture rules context if available
    if [[ -n "$arch_rules" ]]; then
        injection+="Consider these architecture constraints:
${arch_rules}

"
    fi

    injection+="After listing failure modes, address the most critical one in your implementation plan."

    echo "${plan_prompt}${injection}"
}

# Print the failure-mode section: its heading through the next TOP-LEVEL
# heading, keeping any `###` subsections inside it.
#
# Three call sites previously inlined
#     sed -n '/[Ff]ailure [Mm]ode/,/^##\|^#[^#]/p'
# which carried two bugs that cancelled out on macOS and both bit on Linux:
#   * `\|` alternation is a GNU sed extension. BSD sed reads it literally, so
#     the end pattern never matched and sed printed to end of file — quietly
#     scooping up later sections' bullets and inflating the item count.
#   * `^##` also matches `###`, so under GNU sed the range ended at the first
#     `### subsection` *inside* the analysis, yielding zero items and failing
#     validation for plans that were perfectly adequate.
# Hence "passes on macOS, fails on Linux" for the same input. Matching `## ` /
# `# ` with a required following space keeps subsections in.
#
# Interval expressions like {1,2} are unreliable across awk variants (Ubuntu
# defaults to mawk), so the two heading levels are spelled out.
# Usage: _fma_section "$plan_file"
_fma_section() {
    awk '
        !started && /[Ff]ailure [Mm]ode/      { started = 1; print; next }
        started && (/^## [^#]/ || /^# [^#]/)  { exit }
        started                               { print }
    ' "$1" 2>/dev/null || true
}

# Validate plan has adequate failure mode analysis
# Returns 0 if valid, 1 if missing/shallow
# Checks: section exists, at least 3 items, project-specific references
# Usage: validate_failure_modes "$plan_file"
validate_failure_modes() {
    local plan_file="$1"

    [[ ! -f "$plan_file" ]] && return 1

    # Check if failure mode section exists (case-insensitive)
    if ! grep -qi "failure mode" "$plan_file"; then
        return 1  # Section not found
    fi

    local fma_section
    fma_section=$(_fma_section "$plan_file")

    # Count items (lines starting with 1., 2., 3., etc. or bullet points)
    local item_count
    item_count=$(echo "$fma_section" | grep -E '^\s*[0-9]+\.|^\s*-' | wc -l | tr -d ' ')

    if [[ -z "$item_count" ]] || [[ "$item_count" -lt 3 ]]; then
        return 1  # Fewer than 3 items
    fi

    # Check for project-specific references (not just generic platitudes)
    # Look for: file names, function names, design patterns, architectural concepts
    local has_specificity=false

    if echo "$fma_section" | grep -qEi '(\.js|\.ts|\.py|\.go|\.rs|\.java|\.cpp|\.c|\.rb|\.php)(\)|:|,|"|\s)'; then
        has_specificity=true  # References file extensions
    fi

    if echo "$fma_section" | grep -qEi '(function|class|module|component|service|database|cache|queue|api|endpoint)'; then
        has_specificity=true  # References architectural components
    fi

    if echo "$fma_section" | grep -qEi '(race condition|deadlock|stale|timeout|overflow|leak|injection|validate|sanitize)'; then
        has_specificity=true  # References specific failure modes
    fi

    # Also accept if failure modes reference specific project concepts from plan
    # (e.g., mentions of specific modules/patterns discussed in the plan itself)
    # -E, not BRE: `\|` alternation is a GNU grep extension and is read
    # literally by BSD grep, so this matched nothing on macOS.
    if echo "$fma_section" | grep -qiE 'dependency|rollback|revert|transaction'; then
        has_specificity=true
    fi

    if [[ "$has_specificity" == "true" ]]; then
        return 0  # Valid failure mode analysis
    fi

    return 1  # Generic/shallow analysis
}

# Helper to extract failure mode analysis section from plan
# Usage: extract_failure_modes "$plan_file"
extract_failure_modes() {
    local plan_file="$1"

    [[ ! -f "$plan_file" ]] && return 1

    _fma_section "$plan_file" | head -50
}

# Helper to return a validation status for plan rejection
# Usage: get_failure_mode_validation_status "$plan_file"
# Returns: "valid", "missing_section", "too_few_items", "too_generic"
get_failure_mode_validation_status() {
    local plan_file="$1"

    [[ ! -f "$plan_file" ]] && {
        echo "missing_file"
        return 1
    }

    # Check if failure mode section exists
    if ! grep -qi "failure mode" "$plan_file"; then
        echo "missing_section"
        return 1
    fi

    local fma_section
    fma_section=$(_fma_section "$plan_file")

    # Count items
    local item_count
    item_count=$(echo "$fma_section" | grep -E '^\s*[0-9]+\.|^\s*-' | wc -l | tr -d ' ')

    if [[ -z "$item_count" ]] || [[ "$item_count" -lt 3 ]]; then
        echo "too_few_items"
        return 1
    fi

    # Check for specificity
    local has_specificity=false
    if echo "$fma_section" | grep -qEi '\.(js|ts|py|go|rs|java|cpp|c|rb|php)(\)|:|,|"|\s)|function|class|module|component|service|database|cache|queue|api|endpoint'; then
        has_specificity=true
    fi

    if [[ "$has_specificity" != "true" ]]; then
        echo "too_generic"
        return 1
    fi

    echo "valid"
    return 0
}
