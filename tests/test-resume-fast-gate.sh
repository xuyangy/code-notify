#!/bin/bash

# The PostToolUse / ResumeAfterInput hooks run around every tool call. Their
# fast gate must take the slow path (source tmux.sh, ask the server) only when
# THIS pane paused for input: a pause in another window must not slow every
# other window's tool calls.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
flag_dir="$HOME/.claude/notifications/state/resume-pending"
mkdir -p "$flag_dir" "$TEST_DIR/bin"
tmux_log="$TEST_DIR/tmux.calls"

# Any tmux call means the slow path ran. The stub answers nothing useful, so
# the resume itself is a no-op.
cat > "$TEST_DIR/bin/tmux" <<EOF
#!/bin/bash
echo "\$*" >> "$tmux_log"
exit 1
EOF
chmod +x "$TEST_DIR/bin/tmux"

# $1: TMUX_PANE for the hook.
slow_path_taken() {
    local pane="$1"
    rm -f "$tmux_log"
    env TMUX="/tmp/tmux-501/default,123,0" TMUX_PANE="$pane" \
        PATH="$TEST_DIR/bin:/usr/bin:/bin" bash "$NOTIFIER" PostToolUse claude < /dev/null
    [[ -s "$tmux_log" ]]
}

# Window @7 paused from pane %9.
: > "$flag_dir/default.@7.%9"

if slow_path_taken "%3"; then
    fail "a pause in another window sent this pane's tool hook down the slow path"
fi
pass "a pause in another window keeps this pane on the fast exit"

slow_path_taken "%9" || fail "the pausing pane's tool hook did not reach the resume path"
pass "the pausing pane's tool hook reaches the resume path"

rm -f "$flag_dir/default.@7.%9"
if slow_path_taken "%9"; then
    fail "with no flag at all the tool hook took the slow path"
fi
pass "no flag keeps every pane on the fast exit"
