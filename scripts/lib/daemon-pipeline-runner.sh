#!/usr/bin/env bash
# daemon-pipeline-runner.sh <exit_file> <log_file> <command> [args...]
# Runs one daemon-spawned pipeline, appends its output to <log_file> and records its exit code in
# <exit_file> (written atomically when it ends). The daemon tracks this process's PID: it lives
# exactly as long as the pipeline, in a tmux window or in the background, and the exit file gives
# the reaper the real outcome even when it cannot `wait` for the PID (tmux, or a restarted daemon).
set -uo pipefail
exit_file="${1:?exit file}"
log_file="${2:?log file}"
shift 2
rm -f "$exit_file"
"$@" 2>&1 | tee -a "$log_file"
rc="${PIPESTATUS[0]}"
printf '%s\n' "$rc" > "${exit_file}.tmp" && mv "${exit_file}.tmp" "$exit_file"
exit "$rc"
