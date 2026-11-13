#!/bin/bash

# The agent-exit sweep reads every window's watch state as one "|"-separated
# row. The dialog and idle watch contexts end in a project name, so a "|" in
# that name must not reach the stored option: it would shift every later field
# and the approval / idle countdowns would never mature.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.claude/notifications"
printf '%s' "idle_prompt|permission_prompt" > "$HOME/.claude/notifications/notify-types"
project_dir="$TEST_DIR/my|proj"
mkdir -p "$project_dir"
record="$TEST_DIR/set-options"

(
    builtin cd "$project_dir"
    source "$LIB_DIR/utils/tmux.sh"
    # Record option writes instead of talking to a tmux server. A ";"-chained
    # call is taken one command at a time, as tmux does.
    tmux() {
        local -a seg=()
        local arg
        for arg in "$@" ";"; do
            if [[ "$arg" == ";" ]]; then
                if [[ "${seg[0]:-}" == "set-option" ]] && [[ "${seg[1]:-}" == "-w" ]]; then
                    printf '%s=%s\n' "${seg[4]}" "${seg[5]}" >> "$record"
                fi
                seg=()
            else
                seg+=("$arg")
            fi
        done
        return 0
    }
    tmux_agent_exit_schedule_sweep() { return 0; }
    tmux_resume_poll_fingerprint() { printf '%s\n' "111 222"; }

    CODE_NOTIFY_TMUX_AGENT_NAME=antigravity tmux_running_dialog_arm "@2" "%3"
    tmux_idle_watch_arm codex "my|proj" "@2" "%3"
) < /dev/null

dialog_ctx="$(grep '^@code_notify_dialog_ctx=' "$record" | tail -1)"
idle_watch="$(grep '^@code_notify_idle_watch=' "$record" | tail -1)"
[[ -n "$dialog_ctx" ]] || fail "dialog context was not armed"
[[ -n "$idle_watch" ]] || fail "idle watch was not armed"
[[ "$dialog_ctx" != *"|"* ]] || fail "dialog context stored a '|': $dialog_ctx"
[[ "$idle_watch" != *"|"* ]] || fail "idle watch stored a '|': $idle_watch"
[[ "$dialog_ctx" == "@code_notify_dialog_ctx=%3 antigravity my_proj" ]] \
    || fail "dialog context changed more than the separator: $dialog_ctx"
[[ "$idle_watch" == *" settling codex my_proj" ]] \
    || fail "idle watch changed more than the separator: $idle_watch"
pass "watch contexts store a project name without the sweep's '|' separator"
