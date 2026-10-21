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
expect_render() {
    local got
    got="$(render)"
    [[ "$got" == "$2" ]] || fail "$1 (got: $got)"
    pass "$1"
}
render() {
    tmux display-message -p -c "$client" "$(tmux_sessions_line_build_format)" |
        sed -E 's/beta:2 [^ ]+ b2/beta:2 SPIN b2/; s/ 2 [^ ]+ b2/ 2 SPIN b2/'
}

expect_render "priority view: attention, other badges, running; own session left out" '#[align=left] #[bold]beta:0 💬 b0#[nobold]  beta:3 🟢 b3  #[dim]beta:1 🌕 b1  #[nodim]#[dim]beta:2 SPIN b2  #[nodim]'

touch "$TMUX_SESSIONS_LINE_SHOW_CURRENT_FILE"
expect_render "priority view with current on adds the attached session" '#[align=left] #[bold]alpha:1 🙋 a1#[nobold]  #[bold]beta:0 💬 b0#[nobold]  alpha:0 🟢 a0  beta:3 🟢 b3  #[dim]beta:1 🌕 b1  #[nodim]#[dim]beta:2 SPIN b2  #[nodim]'
rm -f "$TMUX_SESSIONS_LINE_SHOW_CURRENT_FILE"

printf 'sessions\n' > "$TMUX_SESSIONS_LINE_VIEW_FILE"
expect_render "sessions view lists the other sessions' windows" '#[align=left] #[bold]beta#[nobold]: #[bold]0 💬 b0#[nobold]  1 🌕 b1  2 SPIN b2  3 🟢 b3  4 b4   '
touch "$TMUX_SESSIONS_LINE_SHOW_CURRENT_FILE"
expect_render "sessions view with current on underlines the attached session" '#[align=left] #[bold]#[underscore]alpha#[nobold]#[nounderscore]: 0 🟢 a0  #[bold]1 🙋 a1#[nobold]   #[bold]beta#[nobold]: #[bold]0 💬 b0#[nobold]  1 🌕 b1  2 SPIN b2  3 🟢 b3  4 b4   '
rm -f "$TMUX_SESSIONS_LINE_SHOW_CURRENT_FILE" "$TMUX_SESSIONS_LINE_VIEW_FILE"
exec 3>&-

tmux_sessions_line_arm
printf 'sessions\n' > "$TMUX_SESSIONS_LINE_VIEW_FILE"
tmux_sessions_line_refresh
check "refresh swaps the installed row to the new view" \
    test "$(opt 'status-format[1]')" == "$(tmux_sessions_line_build_format)" -a "$(opt @code_notify_line_fmt)" == "$(tmux_sessions_line_build_format)"
rm -f "$TMUX_SESSIONS_LINE_VIEW_FILE"
tmux_sessions_line_disarm

# --- attention icons match the notifier ---------------------------------------

notifier_icons="$(grep -o 'BADGE_ICON="[^"]*"' "$ROOT_DIR/lib/code-notify/core/notifier.sh" | cut -d'"' -f2)"
IFS='|' read -r -a attention_icons <<< "$TMUX_SESSIONS_LINE_ATTENTION_ICONS"
for icon in "${attention_icons[@]}"; do
    grep -qxF "$icon" <<< "$notifier_icons" || fail "attention icon $icon is not a notifier badge icon"
done
pass "every attention icon is a notifier badge icon"

echo "All tmux sessions line tests passed"
