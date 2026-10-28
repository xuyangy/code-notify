#!/bin/bash

# The tmux sessions line (cn sessions-line): install/restore bookkeeping, the
# hands-off heal on later prompts, both views, and the attention icon list
# staying in sync with the notifier's badge icons. Runs against a throwaway
# tmux server on its own -L socket, never the user's.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }
check() {
    local name="$1"
    shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}

REAL_TMUX="$(command -v tmux 2>/dev/null || true)"
if [[ -z "$REAL_TMUX" ]]; then
    echo "SKIP: tmux not installed"
    exit 0
fi

SOCK="cn-sessions-line-$$"
test_dir="$(mktemp -d)"
sock_path=""
cleanup() {
    "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
    [[ -n "$sock_path" ]] && rm -f "$sock_path"
    rm -rf "$test_dir"
}
trap cleanup EXIT

export HOME="$test_dir"
mkdir -p "$HOME/.claude/notifications"
unset CODE_NOTIFY_TMUX_RUNNING

"$REAL_TMUX" -L "$SOCK" -f /dev/null new-session -d -s alpha -n a0
"$REAL_TMUX" -L "$SOCK" new-window -d -t alpha -n a1
"$REAL_TMUX" -L "$SOCK" new-session -d -s beta -n b0
"$REAL_TMUX" -L "$SOCK" new-window -d -t beta -n b1
"$REAL_TMUX" -L "$SOCK" new-window -d -t beta -n b2
sock_path="$("$REAL_TMUX" -L "$SOCK" display-message -p '#{socket_path}')"
export TMUX="$sock_path,1,0"
TMUX_PANE="$(tmux list-panes -t alpha:0 -F '#{pane_id}')"
export TMUX_PANE

# shellcheck source=/dev/null
source "$ROOT_DIR/lib/code-notify/utils/tmux.sh"

opt() { tmux show-options -gv "$1" 2>/dev/null; }
fmt="$(tmux_sessions_line_build_format)"
orig_row1="$(opt 'status-format[1]')"

# --- install and restore ----------------------------------------------------

tmux_sessions_line_arm
check "arm adds a second line" \
    test "$(opt status)" == 2 -a "$(opt 'status-format[1]')" == "$fmt"

tmux set-option -g status 3
tmux set-option -g 'status-format[1]' CUSTOM
tmux_sessions_line_arm
check "explicit arm keeps a replaced row and goes past it" \
    test "$(opt 'status-format[1]')" == CUSTOM -a "$(opt @code_notify_line_index)" == 3 -a "$(opt status)" == 4

tmux_sessions_line_disarm
check "disarm keeps the user's newer layout" \
    test "$(opt 'status-format[1]')" == CUSTOM -a "$(opt status)" == 3 -a -z "$(opt 'status-format[3]')"
tmux set-option -g status on
tmux set-option -g 'status-format[1]' "$orig_row1"

tmux_sessions_line_arm
tmux set-option -g 'status-format[1]' OLDFMT
tmux set-option -g @code_notify_line_fmt OLDFMT
tmux_sessions_line_disarm
check "disarm removes a line an older version installed" \
    test "$(opt 'status-format[1]')" == "$orig_row1" -a "$(opt status)" == on

tmux_sessions_line_arm
tmux set-option -gu @code_notify_line_index
tmux_sessions_line_arm
check "arm adopts a line a concurrent arm installed" \
    test "$(opt status)" == 2 -a "$(opt @code_notify_line_index)" == 1 -a "$(opt @code_notify_line_saved_format)" == "$orig_row1"
tmux_sessions_line_disarm

# --- click binding -------------------------------------------------------------

if tmux list-keys -T root -F '#{key_command}' > /dev/null 2>&1; then
    key() { tmux list-keys -T root -F '#{key_command}' MouseDown1Status 2>/dev/null; }
    orig_click="$(key)"
    tmux_sessions_line_arm
    wrapped="$(key)"
    check "arm wraps the click binding" grep -qF "$TMUX_SESSIONS_LINE_CLICK_COND" <<< "$wrapped"
    check "... keeping the old binding for other clicks" grep -qF "{ $orig_click }" <<< "$wrapped"
    tmux_sessions_line_arm
    check "a second arm does not wrap it twice" test "$(key)" == "$wrapped"
    tmux_sessions_line_disarm
    check "disarm restores the click binding" test "$(key)" == "$orig_click"

    printf '%s\n' 'bind-key -n MouseDown1Status display-message "a b" \; select-window -t =' | tmux source-file -
    compound="$(key)"
    tmux_sessions_line_arm
    check "a multi-command binding is wrapped" grep -qF '{ display-message "a b" ; select-window -t = }' <<< "$(key)"
    tmux_sessions_line_disarm
    check "... and restored intact" test "$(key)" == "$compound"

    tmux unbind-key -n MouseDown1Status
    tmux_sessions_line_arm
    tmux_sessions_line_disarm
    check "with no binding before, disarm leaves none" test -z "$(key)"

    tmux_sessions_line_arm
    tmux bind-key -n MouseDown1Status select-window -t =
    tmux_sessions_line_disarm
    check "disarm keeps a binding the user replaced" test "$(key)" == "select-window -t ="

    # Nested braces, a quoted ";", a quoted "\;" and a quoted format.
    printf '%s\n' "bind-key -n MouseDown1Status if -F 1 { display a ; display \"b;c\" } \; display 'x \; y' \; display '#{session_name}'" |
        tmux source-file -
    compound="$(key)"
    tmux_sessions_line_arm
    check "a nested binding is wrapped as one block" \
        grep -qF '{ if-shell -F 1 { display-message a ; display-message "b;c" } ; display-message "x \\; y" ; display-message "#{session_name}" }' <<< "$(key)"
    tmux_sessions_line_disarm
    check "... and restored intact" test "$(key)" == "$compound"
    printf 'bind-key -n MouseDown1Status %s\n' "$orig_click" | tmux source-file -
fi

tmux set-option -t beta status on
check "sessions with their own status are reported" \
    test "$(tmux_sessions_line_local_overrides)" == beta
tmux set-option -u -t beta status

# --- heal on later prompts --------------------------------------------------

touch "$TMUX_SESSIONS_LINE_ENABLED_FILE"
tmux_prompt_submit
check "first prompt on a new server installs the line" \
    test "$(opt status)" == 2 -a "$(opt @code_notify_line_index)" == 1

tmux set-option -g status on
tmux_prompt_submit
check "a prompt leaves a hidden line hidden" test "$(opt status)" == on

tmux set-option -g status 2
tmux set-option -g 'status-format[1]' REPLACED
tmux_prompt_submit
check "a prompt leaves a replaced row alone" \
    test "$(opt 'status-format[1]')" == REPLACED -a "$(opt status)" == 2

tmux set-option -g 'status-format[1]' OLDFMT
tmux set-option -g @code_notify_line_fmt OLDFMT
tmux set-option -g status on
tmux_prompt_submit
check "a prompt upgrades our row in place without showing it" \
    test "$(opt 'status-format[1]')" == "$fmt" -a "$(opt status)" == on

tmux_sessions_line_disarm
CODE_NOTIFY_TMUX_RUNNING=false tmux_prompt_submit
check "first install works with the running indicator disabled" test "$(opt status)" == 2

rm -f "$TMUX_SESSIONS_LINE_ENABLED_FILE"
tmux set-option -g status on
tmux_sessions_line_heal
check "heal is a no-op while disabled" test "$(opt status)" == on
tmux_sessions_line_disarm

# --- views --------------------------------------------------------------------

badge() {
    tmux rename-window -t "$1" "$2 $3"
    tmux set-option -w -t "$1" @code_notify_orig_name "$3"
    tmux set-option -w -t "$1" @code_notify_badged_name "$2 $3"
    tmux set-option -w -t "$1" @code_notify_clear_mode "${4:-engage}"
}
tmux new-window -d -t beta -n b3
tmux new-window -d -t beta -n b4
now="$(date +%s)"
badge alpha:0 🟢 a0
badge alpha:1 🙋 a1
badge beta:0 💬 b0
# Static running icon, then the spinner: fresh, hidden under a badge, expired.
badge beta:1 🌕 b1 running
tmux_spinner_arm
tmux set-option -w -t beta:2 @code_notify_running "$now"
badge beta:3 🟢 b3
tmux set-option -w -t beta:3 @code_notify_running "$now"
tmux set-option -w -t beta:4 @code_notify_running "$((now - TMUX_RUNNING_TTL - 60))"

# The status line renders per client; a control-mode client attached to alpha
# stands in for the user's terminal.
mkfifo "$test_dir/ctl"
tmux -C attach-session -t alpha < "$test_dir/ctl" > /dev/null 2>&1 &
exec 3> "$test_dir/ctl"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    client="$(tmux list-clients -F '#{client_name}' 2>/dev/null | head -n 1)"
    [[ -n "$client" ]] && break
    sleep 0.2
done
[[ -n "$client" ]] || fail "control-mode client did not attach"
# Spinner frames follow the clock; normalize the one fresh spinner item.
# Click ranges are checked on their own below, so render drops them.
expect_render() {
    local got
    got="$(render)"
    [[ "$got" == "$2" ]] || fail "$1 (got: $got)"
    pass "$1"
}
render() {
    tmux display-message -p -c "$client" "$(tmux_sessions_line_build_format)" |
        sed -E 's/ 2 [^ ]+ b2/ 2 SPIN b2/; s/#\[(range=[^]]*|norange)\]//g'
}

chip() { printf '#[reverse] %s #[noreverse]' "$1"; }
A="$(chip alpha)"
B="$(chip beta)"
expect_render "priority view: attention, other badges, running; own session left out" "#[align=left] #[bold]$B 0 💬 b0#[nobold]  $B 3 🟢 b3  #[dim]$B 1 🌕 b1  #[nodim]#[dim]$B 2 SPIN b2  #[nodim]"

b0_id="$(tmux display-message -p -t beta:0 '#{session_id}:#{window_id}')"
check "each priority item is a click range for its session and window" \
    grep -qF "#[range=user|cn$b0_id]#[reverse] beta #[noreverse] 0 " <<< "$(tmux display-message -p -c "$client" "$(tmux_sessions_line_build_format)")"

printf 'right\n' > "$TMUX_SESSIONS_LINE_ALIGN_FILE"
check "align right" test "$(tmux_sessions_line_build_format | cut -c1-15)" == '#[align=right] '
printf 'centre\n' > "$TMUX_SESSIONS_LINE_ALIGN_FILE"
check "align centre" test "$(tmux_sessions_line_build_format | cut -c1-16)" == '#[align=centre] '
printf 'bogus\n' > "$TMUX_SESSIONS_LINE_ALIGN_FILE"
check "an unknown alignment falls back to left" test "$(tmux_sessions_line_align)" == left
rm -f "$TMUX_SESSIONS_LINE_ALIGN_FILE"

touch "$TMUX_SESSIONS_LINE_SHOW_CURRENT_FILE"
expect_render "priority view with current on adds the attached session" "#[align=left] #[bold]$A 1 🙋 a1#[nobold]  #[bold]$B 0 💬 b0#[nobold]  $A 0 🟢 a0  $B 3 🟢 b3  #[dim]$B 1 🌕 b1  #[nodim]#[dim]$B 2 SPIN b2  #[nodim]"
rm -f "$TMUX_SESSIONS_LINE_SHOW_CURRENT_FILE"

printf 'sessions\n' > "$TMUX_SESSIONS_LINE_VIEW_FILE"
expect_render "sessions view lists the other sessions' windows" "#[align=left] $B #[bold]0 💬 b0#[nobold]  1 🌕 b1  2 SPIN b2  3 🟢 b3  4 b4   "
touch "$TMUX_SESSIONS_LINE_SHOW_CURRENT_FILE"
expect_render "sessions view with current on underlines the attached session" "#[align=left] #[underscore]$A#[nounderscore] 0 🟢 a0  #[bold]1 🙋 a1#[nobold]   $B #[bold]0 💬 b0#[nobold]  1 🌕 b1  2 SPIN b2  3 🟢 b3  4 b4   "
rm -f "$TMUX_SESSIONS_LINE_SHOW_CURRENT_FILE" "$TMUX_SESSIONS_LINE_VIEW_FILE"
exec 3>&-

tmux_sessions_line_arm
printf 'sessions\n' > "$TMUX_SESSIONS_LINE_VIEW_FILE"
tmux_sessions_line_refresh
check "refresh swaps the installed row to the new view" \
    test "$(opt 'status-format[1]')" == "$(tmux_sessions_line_build_format)" -a "$(opt @code_notify_line_fmt)" == "$(tmux_sessions_line_build_format)"
rm -f "$TMUX_SESSIONS_LINE_VIEW_FILE"
tmux_sessions_line_disarm

# --- auto hide: shown only while there is something to list -----------------

if tmux_sessions_line_auto_supported; then
    touch "$TMUX_SESSIONS_LINE_ENABLED_FILE"
    lopt() { tmux show-options -qv -t "$1" "$2" 2>/dev/null; }
    monitor() { tmux show-hooks -t "$1" 2>/dev/null | grep -c '^@code_notify_line ' || true; }
    # A monitor samples about once a second; give it a few samples.
    wait_for() {
        local _
        for _ in $(seq 1 20); do
            [[ "$(lopt "$1" status)" == "$2" ]] && return 0
            sleep 0.3
        done
        return 1
    }
    unbadge() {
        tmux set-option -w -t "$1" -u @code_notify_badged_name
        tmux set-option -w -t "$1" -u @code_notify_orig_name
        tmux set-option -w -t "$1" -u @code_notify_clear_mode
        tmux set-option -w -t "$1" -u @code_notify_running
    }

    tmux_sessions_line_arm
    check "auto: each session gets a monitor and its own status" \
        test "$(monitor alpha)" == 1 -a "$(monitor beta)" == 1 -a "$(lopt alpha status)" == 2 -a "$(lopt beta status)" == 2

    unbadge alpha:0
    unbadge alpha:1
    check "auto: the line hides once the other sessions have nothing to list" wait_for beta on
    check "auto: a session whose others still have content keeps it" test "$(lopt alpha status)" == 2

    tmux set-option -w -t alpha:0 @code_notify_running "$(( $(date +%s) - TMUX_RUNNING_TTL + 2 ))"
    check "auto: a live spinner in another session shows the line" wait_for beta 2
    check "auto: an expiring spinner hides it again with no event" wait_for beta on
    unbadge alpha:0

    tmux new-session -d -s gamma
    check "auto: a new session gets its own monitor" wait_for gamma 2
    check "auto: ... and it is marked as ours" test "$(lopt gamma @code_notify_line_auto)" == 1
    tmux kill-session -t gamma

    touch "$TMUX_SESSIONS_LINE_SHOW_CURRENT_FILE"
    tmux_sessions_line_watch_all
    check "auto with current on counts the session's own windows" \
        test "$(lopt alpha status)" == 2 -a "$(lopt beta status)" == 2
    rm -f "$TMUX_SESSIONS_LINE_SHOW_CURRENT_FILE"
    tmux_sessions_line_watch_all

    tmux_sessions_line_unwatch_all
    tmux set-option -t beta status 3
    tmux_sessions_line_watch_all
    check "auto: a session with its own status from before is left alone" \
        test "$(lopt beta status)" == 3 -a "$(monitor beta)" == 0
    tmux set-option -t beta -u status
    tmux_sessions_line_watch_all
    check "auto-owned session status is not reported as an override" \
        test -z "$(tmux_sessions_line_local_overrides)"

    tmux_sessions_line_unwatch_all
    tmux set-option -t beta 'status-format[1]' CUSTOM
    tmux_sessions_line_watch_all
    check "auto: a session with its own status-format is left alone" \
        test "$(monitor beta)" == 0 -a -z "$(lopt beta status)" -a -z "$(lopt beta @code_notify_line_auto)"
    check "... and is reported as an override" test "$(tmux_sessions_line_local_overrides)" == beta
    tmux set-option -t beta -u status-format
    tmux_sessions_line_watch_all

    tmux set-option -t beta 'status-format[1]' CUSTOM
    check "a marked session that gains its own status-format is reported" \
        test "$(tmux_sessions_line_local_overrides)" == beta
    tmux_sessions_line_watch_all
    check "auto: ... and is released by the next watch" \
        test "$(monitor beta)" == 0 -a -z "$(lopt beta status)" -a -z "$(lopt beta @code_notify_line_auto)" -a "$(monitor alpha)" == 1
    tmux set-option -t beta -u status-format
    tmux_sessions_line_watch_all

    touch "$TMUX_SESSIONS_LINE_AUTO_OFF_FILE"
    tmux_sessions_line_watch_all
    check "auto off removes the monitors and the session status" \
        test "$(monitor alpha)" == 0 -a -z "$(lopt alpha status)" -a -z "$(lopt alpha @code_notify_line_auto)" -a "$(opt status)" == 2
    check "auto off removes the session-created hook" \
        test -z "$(tmux show-hooks -g session-created 2>/dev/null | grep -F "[$TMUX_SESSIONS_LINE_HOOK_INDEX]" || true)"
    rm -f "$TMUX_SESSIONS_LINE_AUTO_OFF_FILE"

    # A monitor checks, when it fires, that its session is still ours and the
    # line still sits at its row. alpha is empty here, so beta's line is
    # hidden until alpha gets a badge.
    tmux_sessions_line_watch_all
    check "auto: beta hidden while alpha is empty" wait_for beta on
    tmux set-option -g @code_notify_line_index 3
    badge alpha:0 💬 a0
    sleep 2.5
    check "auto: a monitor does nothing after the line moved" test "$(lopt beta status)" == on
    unbadge alpha:0
    tmux set-option -g @code_notify_line_index 1

    # Installing and removing take turns under one lock.
    tmux_running_transition_lock_acquire sessions-line
    held_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    held_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    tmux_sessions_line_unwatch_all &
    unwatch_pid=$!
    sleep 0.5
    check "auto: removal waits while another run holds the lock" test "$(monitor beta)" == 1
    tmux_running_transition_lock_release "$held_lock" "$held_token"
    wait "$unwatch_pid"
    check "auto: ... and runs once the lock is free" test "$(monitor beta)" == 0

    # A removal that cannot get the lock in time reports it instead of
    # claiming the monitors are gone.
    tmux_sessions_line_watch_all
    tmux_running_transition_lock_acquire sessions-line
    held_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    held_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    unwatch_rc=0
    TMUX_SESSIONS_LINE_LOCK_TIMEOUT_MS=300 tmux_sessions_line_unwatch_all || unwatch_rc=$?
    check "auto: a removal that times out returns failure" \
        test "$unwatch_rc" == 1 -a "$(monitor beta)" == 1
    tmux_running_transition_lock_release "$held_lock" "$held_token"
    tmux_sessions_line_unwatch_all
    check "auto: ... and a retry removes the monitors" test "$(monitor beta)" == 0

    tmux_sessions_line_watch_all
    tmux_sessions_line_disarm
    check "disarm removes the monitors and the session status" \
        test "$(monitor beta)" == 0 -a -z "$(lopt beta status)" -a "$(opt status)" == on

    tmux_sessions_line_arm
    tmux set-option -gu @code_notify_line_index
    tmux_sessions_line_disarm
    check "disarm removes leftover monitors when the line is gone" \
        test "$(monitor alpha)" == 0 -a "$(monitor beta)" == 0 -a -z "$(lopt beta @code_notify_line_auto)"
    tmux set-option -g status on
    rm -f "$TMUX_SESSIONS_LINE_ENABLED_FILE"
else
    echo "SKIP: auto hide needs tmux 3.8 (set-hook -B)"
fi

# --- attention icons match the notifier ---------------------------------------

notifier_icons="$(grep -o 'BADGE_ICON="[^"]*"' "$ROOT_DIR/lib/code-notify/core/notifier.sh" | cut -d'"' -f2)"
IFS='|' read -r -a attention_icons <<< "$TMUX_SESSIONS_LINE_ATTENTION_ICONS"
for icon in "${attention_icons[@]}"; do
    grep -qxF "$icon" <<< "$notifier_icons" || fail "attention icon $icon is not a notifier badge icon"
done
pass "every attention icon is a notifier badge icon"

echo "All tmux sessions line tests passed"
