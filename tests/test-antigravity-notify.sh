#!/bin/bash

# Antigravity CLI (agy) notification mapping tests.
#
# agy passes no argv to a hook and delivers a JSON payload on stdin; code-notify
# wraps each lifecycle event as "agy:<Event>" + "antigravity". This exercises the
# notifier's antigravity branch directly (no agy binary required):
#   * PreToolUse           -> "Input Required" (permission prompt)
#   * PostToolUse + error  -> "Error" (string OR structured HookErrorMessage)
#   * PostToolUse, no error -> debounced "Task Complete" (via the watcher)
#   * Stop                 -> "Task Complete"
# Project name comes from workspacePaths[0].

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

wait_for_lines() {
    local file="$1"
    local expected_lines="$2"

    for _ in $(seq 1 60); do
        if [[ -f "$file" ]] && [[ $(wc -l < "$file") -ge "$expected_lines" ]]; then
            return 0
        fi
        sleep 0.1
    done

    return 1
}

# Project extraction relies on jq or python3; skip cleanly if neither exists.
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: jq or python3 required for Antigravity notify test"
    exit 0
fi

run_agy_notifier() {
    local fake_path="$1"
    local event="$2"
    local payload="$3"

    printf '%s' "$payload" \
    | PATH="$fake_path" \
      CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
      CODE_NOTIFY_AGY_DEBOUNCE_SECONDS=1 \
      CODE_NOTIFY_TAIL_SYNC=1 \
      bash "$NOTIFIER" "agy:$event" "antigravity"
}

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
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
        echo "SKIP: unsupported OS for Antigravity notify test"
        exit 0
        ;;
esac

chmod +x "$fake_bin"/*

fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

ws() { printf '"workspacePaths":["/tmp/work/%s"]' "$1"; }

# 1) PreToolUse while agy waits for approval -> Input Required.
run_agy_notifier "$fake_path" "PreToolUse" \
    "{\"conversationId\":\"c-pre\",\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"echo hi\"}},$(ws projInput)}"

# 2) PostToolUse with a STRUCTURED error -> Error (must not be read as success).
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-err\",\"error\":{\"message\":\"build blew up\",\"code\":1},$(ws projErr)}"

# 3) PostToolUse with empty error -> debounced Task Complete (fires from watcher).
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-done\",\"error\":\"\",$(ws projDone)}"

# 4) Native Stop event -> Task Complete (dormant in agy today, but mapped).
run_agy_notifier "$fake_path" "Stop" \
    "{\"conversationId\":\"c-stop\",$(ws projStop)}"

# 5) A successful step that arms the debounce, immediately followed by an error
#    in the same conversation: the error must cancel the pending completion, so
#    we expect an Error and NO Task Complete for projCancel.
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-cancel\",\"error\":\"\",$(ws projCancel)}"
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-cancel\",\"error\":{\"message\":\"late failure\"},$(ws projCancel)}"

# 6) A successful step arms the debounce, then a PreToolUse (waiting for
#    approval) arrives in the same conversation: the agent is not done, so the
#    PreToolUse must cancel the pending completion. Expect Input Required and
#    NO Task Complete for projApprove.
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-approve\",\"error\":\"\",$(ws projApprove)}"
run_agy_notifier "$fake_path" "PreToolUse" \
    "{\"conversationId\":\"c-approve\",\"toolCall\":{\"name\":\"run_command\"},$(ws projApprove)}"

# Five fire synchronously (projInput, projErr, projStop, projCancel error,
# projApprove input); the debounced projDone complete arrives ~1s later -> six.
wait_for_lines "$notification_log" 6 || fail "expected six Antigravity notification deliveries"
# Give any (incorrectly) pending debounce watchers time to fire before asserting.
sleep 2

grep -q "Input Required - projInput" "$notification_log" \
    || fail "PreToolUse did not map to an input-required notification"
grep -q "Error - projErr" "$notification_log" \
    || fail "structured PostToolUse error was not classified as a failure"
grep -q "Task Complete - projDone" "$notification_log" \
    || fail "debounced PostToolUse did not produce a task-complete notification"
grep -q "Task Complete - projStop" "$notification_log" \
    || fail "Stop event did not map to a task-complete notification"
grep -q "Error - projCancel" "$notification_log" \
    || fail "late error in the cancel scenario was not reported"
grep -q "Input Required - projApprove" "$notification_log" \
    || fail "PreToolUse in the approval scenario was not reported"

# A PostToolUse error must NOT also be reported as complete for the same project.
grep -q "Task Complete - projErr" "$notification_log" \
    && fail "error payload was incorrectly reported as task complete"
# The error must have cancelled the earlier debounced completion.
grep -q "Task Complete - projCancel" "$notification_log" \
    && fail "error did not cancel the pending debounced completion"
# A PreToolUse (waiting for approval) must cancel the pending completion.
grep -q "Task Complete - projApprove" "$notification_log" \
    && fail "PreToolUse did not cancel the pending debounced completion"

# 7) Regression (P1): error alerts must honour the kill switch (cn off). With the
#    disabled marker present, a PostToolUse error must NOT be delivered.
lines_before="$(wc -l < "$notification_log")"
touch "$HOME/.claude/notifications/disabled"
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-killed\",\"error\":{\"message\":\"should be silenced\"},$(ws projKilled)}"
rm -f "$HOME/.claude/notifications/disabled"
grep -q "projKilled" "$notification_log" \
    && fail "error alert bypassed the kill switch (cn off)"
[[ "$(wc -l < "$notification_log")" == "$lines_before" ]] \
    || fail "an alert was delivered while notifications were disabled"

# 8) Regression (P2): a native Stop must cancel the pending PostToolUse debounce
#    so completion fires once, not twice. Arm the debounce, then send Stop in the
#    same conversation and wait out the debounce window for any second delivery.
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-stoponce\",\"error\":\"\",$(ws projStopOnce)}"
run_agy_notifier "$fake_path" "Stop" \
    "{\"conversationId\":\"c-stoponce\",$(ws projStopOnce)}"
sleep 2
stop_once_count="$(grep -c "Task Complete - projStopOnce" "$notification_log")"
[[ "$stop_once_count" == "1" ]] \
    || fail "native Stop produced $stop_once_count completion alerts (expected 1)"

pass "Antigravity maps PreToolUse/PostToolUse/Stop into the correct notifications"
