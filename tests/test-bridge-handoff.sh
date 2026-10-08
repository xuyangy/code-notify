#!/bin/bash

# agent-bridge-tmux mirrors its bridge status into the pane option
# @agent_bridge_status. A Stop in a pane whose bridge is pending handed the
# turn to the peer agent: it is announced with handoff wording and its idle
# reminder is dropped. Every other bridge status is an ordinary completion.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export CODE_NOTIFY_TAIL_SYNC=1
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin" "$log_dir"

case "$(uname -s)" in
    Darwin)
        notification_log="$log_dir/terminal-notifier.log"
        cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then exit 0; fi
printf '%s\n' "\$*" >> "$notification_log"
EOF
        ;;
    Linux)
        notification_log="$log_dir/notify-send.log"
        cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        ;;
    *)
        echo "SKIP: unsupported OS for bridge-handoff test"
        exit 0
        ;;
esac

# The fake tmux answers only the pane-option read, from a file the test
# rewrites; every other call fails, as it would with no server.
label_file="$test_dir/label"
cat > "$fake_bin/tmux" <<EOF
#!/bin/bash
if [[ "\$*" == "show-options -pqv -t %1 @agent_bridge_status" ]] && [[ -f "$label_file" ]]; then
    cat "$label_file"
    exit 0
fi
exit 1
EOF
chmod +x "$fake_bin"/*
fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

run_notifier() {
    local hook_type="$1" tool="$2" payload="$3"

    printf '%s\n' "$payload" | \
        PATH="$fake_path" \
        CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=0 \
        bash "$NOTIFIER" "$hook_type" "$tool" test-project
}

notification_lines() {
    if [[ -f "$notification_log" ]]; then
        wc -l < "$notification_log"
    else
        echo 0
    fi
}

last_notification() {
    tail -n 1 "$notification_log"
}

set_label() {
    printf '%s\n' "$1" > "$label_file"
}

stop_payload='{"session_id":"sess1","stop_hook_active":false,"background_tasks":[]}'
idle_payload='{"session_id":"sess1","notification_type":"idle_prompt"}'
future=$(( $(date +%s) + 3600 ))
past=$(( $(date +%s) - 60 ))

export TMUX="$test_dir/tmux-socket,1,0"
export TMUX_PANE="%1"

# A pending bridge: the Stop still notifies, worded as a handoff.
set_label "pending:$future"
run_notifier stop claude "$stop_payload"
[[ "$(notification_lines)" -eq 1 ]] || fail "pending bridge Stop should still notify"
[[ "$(last_notification)" == *"Claude sent a bridge message"* ]] ||
    fail "pending bridge Stop should use the handoff message"
[[ "$(last_notification)" == *"Bridge Message Sent"* ]] ||
    fail "pending bridge Stop should use the handoff subtitle"
pass "pending bridge Stop is announced as a handoff"

# The long wording says nothing is asked of the user.
CODE_NOTIFY_BANNER_WORDING=long run_notifier stop claude "$stop_payload"
[[ "$(last_notification)" == *"sent a bridge message to the other agent. No action needed."* ]] ||
    fail "long handoff wording should say no action is needed"
pass "long handoff wording says no action is needed"

# The idle reminder that follows a handoff is dropped.
lines_before="$(notification_lines)"
run_notifier notification claude "$idle_payload"
[[ "$(notification_lines)" -eq "$lines_before" ]] ||
    fail "idle reminder should be hidden while the bridge is pending"
pass "idle reminder is hidden while the bridge is pending"

# Any agent in the pane gets the same wording.
run_notifier stop codex '{"hook_event_name":"Stop"}'
[[ "$(last_notification)" == *"Codex sent a bridge message"* ]] ||
    fail "Codex Stop should use the handoff message"
pass "handoff wording applies to Codex"

# Every other label is an ordinary completion with an ordinary idle reminder.
for label in "pending:$past" "pending:" "pending:soon" unconfirmed sending \
    awaiting_reply terminated timed_out ""; do
    set_label "$label"
    lines_before="$(notification_lines)"
    run_notifier stop claude "$stop_payload"
    [[ "$(notification_lines)" -eq $((lines_before + 1)) ]] ||
        fail "label '$label' should deliver a completion"
    [[ "$(last_notification)" != *"bridge message"* ]] ||
        fail "label '$label' should use the normal completion message"
    [[ "$(last_notification)" == *"Task Complete"* ]] ||
        fail "label '$label' should use the normal completion subtitle"
    run_notifier notification claude "$idle_payload"
    [[ "$(notification_lines)" -eq $((lines_before + 2)) ]] ||
        fail "label '$label' should keep the idle reminder"
done
pass "other bridge statuses are ordinary completions"

# No label at all, and no tmux at all.
rm -f "$label_file"
run_notifier stop claude "$stop_payload"
[[ "$(last_notification)" != *"bridge message"* ]] ||
    fail "a pane without the option should use the normal completion message"
set_label "pending:$future"
unset TMUX TMUX_PANE
run_notifier stop claude "$stop_payload"
[[ "$(last_notification)" != *"bridge message"* ]] ||
    fail "a Stop outside tmux should use the normal completion message"
pass "no label and no tmux are ordinary completions"

# Errors keep their own wording while a bridge is pending.
export TMUX="$test_dir/tmux-socket,1,0"
export TMUX_PANE="%1"
run_notifier error claude '{}'
[[ "$(last_notification)" != *"bridge message"* ]] ||
    fail "an error should not use the handoff message"
pass "errors are not reworded"

echo "All bridge-handoff tests passed"
