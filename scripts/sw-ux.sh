#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright ux — Premium UX Enhancement Layer                             ║
# ║  Themes · Animations · Keyboard Shortcuts · Accessibility · Formatting   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
_COMPAT="$SCRIPT_DIR/lib/compat.sh"
# shellcheck source=lib/compat.sh
[[ -f "$_COMPAT" ]] && source "$_COMPAT"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

# ─── UX Configuration ──────────────────────────────────────────────────────
UX_CONFIG_GLOBAL="${HOME}/.shipwright/ux-config.json"
UX_CONFIG_REPO="./.claude/ux-config.json"

# Detect accessibility modes
should_disable_colors() {
    [[ -n "${NO_COLOR:-}" ]] || [[ "${FORCE_COLOR:-}" == "0" ]] || [[ -n "${CLICOLOR_FORCE:-}" && "$CLICOLOR_FORCE" == "0" ]]
}

has_reduced_motion() {
    [[ -n "${PREFERS_REDUCED_MOTION:-}" ]]
}

# ─── Initialize UX Config ──────────────────────────────────────────────────
init_ux_config() {
    local config_file="$1"
    mkdir -p "$(dirname "$config_file")"

    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" <<'EOF'
{
  "theme": "dark",
  "spinner": "dots",
  "animations_enabled": true,
  "sound_enabled": false,
  "reduced_motion": false,
  "high_contrast": false,
  "theme_custom": {}
}
EOF
    fi
}

# ─── Theme System ──────────────────────────────────────────────────────────

# Theme data using functions (bash 3.2 compatible - no associative arrays)
theme_dark() {
    echo "primary=#00d4ff"
    echo "secondary=#7c3aed"
    echo "tertiary=#0066ff"
    echo "success=#4ade80"
    echo "warning=#f59e0b"
    echo "error=#f87171"
    echo "bg=#0f172a"
    echo "fg=#f1f5f9"
    echo "dim=#64748b"
}

theme_light() {
    echo "primary=#0066ff"
    echo "secondary=#7c3aed"
    echo "tertiary=#06b6d4"
    echo "success=#059669"
    echo "warning=#d97706"
    echo "error=#dc2626"
    echo "bg=#ffffff"
    echo "fg=#1e293b"
    echo "dim=#94a3b8"
}

theme_minimal() {
    echo "primary=#000000"
    echo "secondary=#808080"
    echo "tertiary=#808080"
    echo "success=#000000"
    echo "warning=#000000"
    echo "error=#000000"
    echo "bg=#ffffff"
    echo "fg=#000000"
    echo "dim=#cccccc"
}

theme_cyberpunk() {
    echo "primary=#ff006e"
    echo "secondary=#00f5ff"
    echo "tertiary=#ffbe0b"
    echo "success=#00ff41"
    echo "warning=#ffbe0b"
    echo "error=#ff006e"
    echo "bg=#0a0e27"
    echo "fg=#00f5ff"
    echo "dim=#555580"
}

theme_ocean() {
    echo "primary=#0ea5e9"
    echo "secondary=#06b6d4"
    echo "tertiary=#0891b2"
    echo "success=#10b981"
    echo "warning=#f59e0b"
    echo "error=#ef4444"
    echo "bg=#001f3f"
    echo "fg=#e0f2fe"
    echo "dim=#38bdf8"
}

get_theme() {
    local theme_name="${1:-dark}"
    case "$theme_name" in
        light)     theme_light ;;
        minimal)   theme_minimal ;;
        cyberpunk) theme_cyberpunk ;;
        ocean)     theme_ocean ;;
        *)         theme_dark ;;
    esac
}

hex_to_rgb() {
    local hex="${1#\#}"
    printf '%d;%d;%d' 0x"${hex:0:2}" 0x"${hex:2:2}" 0x"${hex:4:2}"
}

# Get color code from theme
get_color() {
    local color_name="$1"
    local theme="${2:-dark}"

    if should_disable_colors; then
        return 0
    fi

    local hex
    hex=$(get_theme "$theme" | grep "^${color_name}=" | cut -d= -f2)

    if [[ -n "$hex" ]]; then
        local rgb
        rgb=$(hex_to_rgb "$hex")
        echo -ne "\033[38;2;${rgb}m"
    fi
}

list_themes() {
    info "Available themes:"
    for theme in dark light minimal cyberpunk ocean; do
        echo "  ${CYAN}${theme}${RESET}"
    done
}

set_theme() {
    local theme="$1"

    init_ux_config "$UX_CONFIG_GLOBAL"

    if jq --arg theme "$theme" '.theme = $theme' "$UX_CONFIG_GLOBAL" > "${UX_CONFIG_GLOBAL}.tmp" 2>/dev/null; then
        mv "${UX_CONFIG_GLOBAL}.tmp" "$UX_CONFIG_GLOBAL"
        success "Theme set to: ${CYAN}${theme}${RESET}"
        emit_event "ux_theme_changed" "theme=$theme"
    else
        error "Failed to set theme"
        return 1
    fi
}

preview_theme() {
    local theme="${1:-dark}"

    echo ""
    info "Preview of ${CYAN}${theme}${RESET} theme:"
    echo ""

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        local rgb
        rgb=$(hex_to_rgb "$value")
        printf "  %-12s ${value}  \033[38;2;${rgb}m████████████${RESET}\n" "$key"
    done < <(get_theme "$theme")
    echo ""
}

# ─── Spinner Animations ────────────────────────────────────────────────────

spinner_dots() {
    echo "⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏"
}

spinner_braille() {
    echo "⠋ ⠙ ⠚ ⠒ ⠂ ⠂ ⠒ ⠲ ⠴ ⠦"
}

spinner_moon() {
    echo "🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘"
}

spinner_arrows() {
    echo "← ↖ ↑ ↗ → ↘ ↓ ↙"
}

spinner_bounce() {
    echo "⠁ ⠂ ⠄ ⠂"
}

get_spinner() {
    local style="${1:-dots}"
    case "$style" in
        braille) spinner_braille ;;
        moon)    spinner_moon ;;
        arrows)  spinner_arrows ;;
        bounce)  spinner_bounce ;;
        *)       spinner_dots ;;
    esac
}

animate_spinner() {
    local message="$1"
    local duration="${2:-10}"
    local style="${3:-dots}"

    if has_reduced_motion; then
        echo "⏳ $message"
        sleep "$duration"
        return 0
    fi

    local spinner_str
    spinner_str="$(get_spinner "$style")"
    local i=0
    local end_time=$(($(date +%s) + duration))

    while [[ $(date +%s) -lt $end_time ]]; do
        # Parse space-separated spinner frames
        local frame
        frame=$(echo "$spinner_str" | awk '{for(n=1;n<=NF;n++) if((n-1)==('$((i % 10))')) print $n}')
        printf "\r${frame} $message"
        i=$((i + 1))
        sleep 0.1
    done
    printf "\r%-80s\r" ""
}

list_spinners() {
    info "Available spinners:"
    for style in dots braille moon arrows bounce; do
        printf "  ${CYAN}%-12s${RESET} "
        local spinner_str
        spinner_str="$(get_spinner "$style")"
        echo "$spinner_str" | awk '{for(i=1;i<=3 && i<=NF;i++) printf "%s ", $i; print "..."}'
    done
}

# ─── Progress Bar ──────────────────────────────────────────────────────────
show_progress() {
    local current="$1"
    local total="$2"
    local label="${3:-Progress}"

    local percent=$((current * 100 / total))
    local filled=$((percent / 5))
    local empty=$((20 - filled))

    printf "\r${CYAN}${label}${RESET} ["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' '-'
    printf "] %3d%%   " "$percent"
}

# ─── Box Drawing Helpers ───────────────────────────────────────────────────
box_title() {
    local title="$1"
    local width="${2:-70}"

    echo "╔$(printf '═%.0s' $(seq 1 $((width-2))))╗"
    printf "║ %-$((width-3))s║\n" "$title"
    echo "╚$(printf '═%.0s' $(seq 1 $((width-2))))╝"
}

box_section() {
    local title="$1"
    local width="${2:-70}"

    echo "┌─ ${CYAN}${title}${RESET}"
    echo "│"
}

box_end() {
    echo "└─"
}

# ─── Table Formatting ──────────────────────────────────────────────────────
table_header() {
    local cols=("$@")
    local widths=()

    # Calculate column widths
    for col in "${cols[@]}"; do
        widths+=($((${#col} + 2)))
    done

    # Print header
    for i in "${!cols[@]}"; do
        printf "%-${widths[$i]}s" "${cols[$i]}"
    done
    echo ""

    # Print separator
    for w in "${widths[@]}"; do
        printf '%*s' "$w" | tr ' ' '─'
    done
    echo ""
}

table_row() {
    local cols=("$@")
    local widths=()

    # This is a simple implementation; in production you'd track column widths
    for col in "${cols[@]}"; do
        printf "%-20s" "$col"
    done
    echo ""
}

# ─── Keyboard Shortcuts System ─────────────────────────────────────────────

show_shortcuts() {
    box_title "Keyboard Shortcuts"
    echo ""

    # Define shortcuts as separate lines (bash 3.2 compatible)
    printf "  ${CYAN}%-20s${RESET} %s\n" "q" "Exit the current menu"
    printf "  ${CYAN}%-20s${RESET} %s\n" "h" "Show help overlay"
    printf "  ${CYAN}%-20s${RESET} %s\n" "t" "Cycle through themes"
    printf "  ${CYAN}%-20s${RESET} %s\n" "s" "Toggle notification sound"
    printf "  ${CYAN}%-20s${RESET} %s\n" "m" "Toggle animation/reduced motion"
    printf "  ${CYAN}%-20s${RESET} %s\n" "c" "Toggle high-contrast mode"
    printf "  ${CYAN}%-20s${RESET} %s\n" "1-5" "Jump to pipeline stage 1-5"
    printf "  ${CYAN}%-20s${RESET} %s\n" "space" "Pause or resume pipeline"
    printf "  ${CYAN}%-20s${RESET} %s\n" "r" "Reload configuration"

    box_end
}

# ─── Accessibility Support ────────────────────────────────────────────────
set_high_contrast() {
    init_ux_config "$UX_CONFIG_GLOBAL"

    if jq '.high_contrast = true' "$UX_CONFIG_GLOBAL" > "${UX_CONFIG_GLOBAL}.tmp" 2>/dev/null; then
        mv "${UX_CONFIG_GLOBAL}.tmp" "$UX_CONFIG_GLOBAL"
        success "High contrast mode enabled"
        emit_event "ux_accessibility" "feature=high_contrast"
    fi
}

set_reduced_motion() {
    init_ux_config "$UX_CONFIG_GLOBAL"
    export PREFERS_REDUCED_MOTION=1

    if jq '.reduced_motion = true' "$UX_CONFIG_GLOBAL" > "${UX_CONFIG_GLOBAL}.tmp" 2>/dev/null; then
        mv "${UX_CONFIG_GLOBAL}.tmp" "$UX_CONFIG_GLOBAL"
        success "Reduced motion mode enabled"
        emit_event "ux_accessibility" "feature=reduced_motion"
    fi
}

enable_screen_reader_mode() {
    # Disable colors and animations for screen reader compatibility
    export NO_COLOR=1
    export FORCE_COLOR=0
    export PREFERS_REDUCED_MOTION=1

    # Propagate to tmux global environment so new panes inherit
    if [[ -n "${TMUX:-}" ]]; then
        tmux set-environment -g NO_COLOR 1
        tmux set-environment -g FORCE_COLOR 0
        tmux set-environment -g PREFERS_REDUCED_MOTION 1
    fi

    success "Screen reader mode enabled (colors and animations disabled)"
    emit_event "ux_accessibility" "feature=screen_reader"
}

disable_screen_reader_mode() {
    unset NO_COLOR
    unset FORCE_COLOR
    unset PREFERS_REDUCED_MOTION

    # Remove from tmux global environment
    if [[ -n "${TMUX:-}" ]]; then
        tmux set-environment -g -u NO_COLOR 2>/dev/null || true
        tmux set-environment -g -u FORCE_COLOR 2>/dev/null || true
        tmux set-environment -g -u PREFERS_REDUCED_MOTION 2>/dev/null || true
    fi

    success "Screen reader mode disabled (colors and animations restored)"
    emit_event "ux_accessibility" "feature=screen_reader_disabled"
}

# ─── Formatting Helpers ───────────────────────────────────────────────────
format_diff_line() {
    local line="$1"

    case "$line" in
        +*) echo -e "${GREEN}${line}${RESET}" ;;
        -*) echo -e "${RED}${line}${RESET}" ;;
        @@*) echo -e "${BLUE}${line}${RESET}" ;;
        *)  echo "$line" ;;
    esac
}

format_tree() {
    local depth="$1"
    local name="$2"
    local is_last="${3:-true}"

    local indent=""
    for _ in $(seq 1 "$depth"); do
        indent+="  "
    done

    local prefix="├─"
    [[ "$is_last" == "true" ]] && prefix="└─"

    echo "${indent}${prefix} ${name}"
}

# ─── Notification Sounds ───────────────────────────────────────────────────
notify_complete() {
    local message="${1:-Complete}"

    init_ux_config "$UX_CONFIG_GLOBAL"
    local sound_enabled
    sound_enabled=$(jq -r '.sound_enabled // false' "$UX_CONFIG_GLOBAL" 2>/dev/null || echo "false")

    if [[ "$sound_enabled" == "true" ]]; then
        # Use system beep (works on macOS and Linux)
        printf '\a'
    fi

    success "$message"
    emit_event "ux_notification" "type=complete" "message=$message"
}

notify_error() {
    local message="${1:-Error occurred}"

    init_ux_config "$UX_CONFIG_GLOBAL"
    local sound_enabled
    sound_enabled=$(jq -r '.sound_enabled // false' "$UX_CONFIG_GLOBAL" 2>/dev/null || echo "false")

    if [[ "$sound_enabled" == "true" ]]; then
        printf '\a\a'  # Double beep for errors
    fi

    error "$message"
    emit_event "ux_notification" "type=error" "message=$message"
}

# ─── Configuration Management ──────────────────────────────────────────────
show_config() {
    init_ux_config "$UX_CONFIG_GLOBAL"

    info "UX Configuration:"
    if [[ -f "$UX_CONFIG_GLOBAL" ]]; then
        jq '.' "$UX_CONFIG_GLOBAL" 2>/dev/null || cat "$UX_CONFIG_GLOBAL"
    else
        echo "No configuration found"
    fi
}

reset_config() {
    rm -f "$UX_CONFIG_GLOBAL"
    init_ux_config "$UX_CONFIG_GLOBAL"
    success "UX configuration reset to defaults"
    emit_event "ux_reset" "scope=global"
}

# ─── Demo Mode ──────────────────────────────────────────────────────────────
run_demo() {
    clear

    box_title "Shipwright UX Enhancement System Demo"
    echo ""

    # Demo themes
    info "Theme Previews:"
    for theme in dark light cyberpunk ocean; do
        preview_theme "$theme"
        sleep 0.5
    done

    # Demo spinners
    info "Spinner Styles:"
    for style in dots braille moon arrows; do
        printf "  ${CYAN}%-12s${RESET} " "$style"
        animate_spinner "Loading" 2 "$style"
        echo " ${GREEN}✓${RESET}"
    done

    echo ""
    info "Progress Bar Demo:"
    for i in {0..100..10}; do
        show_progress "$i" 100 "Building"
        sleep 0.3
    done
    printf "\n"

    # Demo box drawing
    echo ""
    info "Box Drawing Helpers:"
    box_title "Example Section"
    box_section "Content Area"
    echo "  This is sample content with structured formatting"
    box_end

    echo ""
    show_shortcuts

    echo ""
    success "Demo complete!"
}

# ─── Help Text ──────────────────────────────────────────────────────────────
show_help() {
    cat <<'EOF'
shipwright ux — Premium UX Enhancement Layer

USAGE
  shipwright ux <subcommand> [options]

SUBCOMMANDS
  theme <name>              Set theme (dark, light, minimal, cyberpunk, ocean)
  theme list                Show available themes
  theme preview [name]      Preview a theme

  spinner [style]           Show spinner style (dots, braille, moon, arrows, bounce)
  spinner list              Show all spinner styles

  config show               Display current UX configuration
  config reset              Reset to default configuration

  shortcuts                 Show keyboard shortcut reference

  accessibility             Configure accessibility options
    --high-contrast         Enable high contrast mode
    --reduced-motion        Enable reduced motion (no animations)
    --screen-reader         Full screen reader mode

  demo                      Run interactive UX feature demo
  help                      Show this help message

OPTIONS
  --no-color               Disable all color output
  --prefers-reduced-motion Disable animations

EXAMPLES
  shipwright ux theme dark
  shipwright ux theme preview cyberpunk
  shipwright ux spinner list
  shipwright ux accessibility --high-contrast
  shipwright ux demo

CONFIGURATION FILES
  Global:  ~/.shipwright/ux-config.json
  Project: ./.claude/ux-config.json (overrides global)

EOF
}

# ─── Main Command Router ──────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        theme)
            local theme_cmd="${1:-list}"
            shift 2>/dev/null || true
            case "$theme_cmd" in
                list)
                    list_themes
                    ;;
                preview)
                    preview_theme "${1:-dark}"
                    ;;
                *)
                    set_theme "$theme_cmd"
                    ;;
            esac
            ;;
        spinner)
            local spinner_cmd="${1:-dots}"
            case "$spinner_cmd" in
                list)
                    list_spinners
                    ;;
                *)
                    animate_spinner "Demo animation" 3 "$spinner_cmd"
                    echo ""
                    success "Spinner demo complete"
                    ;;
            esac
            ;;
        config)
            local config_cmd="${1:-show}"
            case "$config_cmd" in
                show)
                    show_config
                    ;;
                reset)
                    reset_config
                    ;;
                *)
                    error "Unknown config command: $config_cmd"
                    exit 1
                    ;;
            esac
            ;;
        shortcuts)
            show_shortcuts
            ;;
        accessibility)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --high-contrast)
                        set_high_contrast
                        ;;
                    --reduced-motion)
                        set_reduced_motion
                        ;;
                    --screen-reader)
                        enable_screen_reader_mode
                        ;;
                    --no-screen-reader)
                        disable_screen_reader_mode
                        ;;
                    *)
                        error "Unknown accessibility option: $1"
                        exit 1
                        ;;
                esac
                shift
            done
            ;;
        demo)
            run_demo
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Source guard: allow direct execution and sourcing
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
