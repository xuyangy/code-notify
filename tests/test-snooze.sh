#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

wait_for_lines() {
    local file="$1"
    local expected_lines="$2"

    for _ in $(seq 1 40); do
        if [[ -f "$file" ]] && [[ $(wc -l < "$file") -ge "$expected_lines" ]]; then
            return 0
        fi
        sleep 0.05
    done

    return 1
}

run_notifier() {
    local fake_path="$1"
    local subtype="$2"

    printf '{"type":"%s"}\n' "$subtype" | \
        PATH="$fake_path" \
        bash "$NOTIFIER" notification claude snooze-test
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
        echo "SKIP: unsupported OS for snooze test"
        exit 0
        ;;
esac

chmod +x "$fake_bin"/*
fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

snooze_file="$HOME/.claude/notifications/snooze-until"

# --- baseline: approval prompt delivers ---
run_notifier "$fake_path" "permission_prompt"
wait_for_lines "$notification_log" 1 || fail "baseline notification was not delivered"

# --- active snooze silences everything, including approval prompts ---
PATH="$fake_path" "$ROOT_DIR/bin/code-notify" snooze 5m >/dev/null
[[ -f "$snooze_file" ]] || fail "snooze command should write the marker file"

run_notifier "$fake_path" "permission_prompt"
run_notifier "$fake_path" "idle_prompt"
sleep 0.3
[[ $(wc -l < "$notification_log") -eq 1 ]] || fail "snoozed notifications should be suppressed"

status_output=$(PATH="$fake_path" "$ROOT_DIR/bin/code-notify" snooze status)
printf '%s' "$status_output" | grep -q "snoozed" || fail "snooze status should report active snooze"

# --- snooze off resumes immediately ---
PATH="$fake_path" "$ROOT_DIR/bin/code-notify" snooze off >/dev/null
[[ ! -f "$snooze_file" ]] || fail "snooze off should remove the marker file"

run_notifier "$fake_path" "permission_prompt"
wait_for_lines "$notification_log" 2 || fail "notifications should resume after snooze off"

# --- expired snooze is cleaned up lazily and does not suppress ---
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$snooze_file"
run_notifier "$fake_path" "permission_prompt"
wait_for_lines "$notification_log" 3 || fail "expired snooze should not suppress notifications"
[[ ! -f "$snooze_file" ]] || fail "expired snooze marker should be removed"

# --- invalid durations are rejected ---
if PATH="$fake_path" "$ROOT_DIR/bin/code-notify" snooze "2 hours" >/dev/null 2>&1; then
    fail "invalid duration should be rejected"
fi

pass "snooze pauses all notifications, expires lazily, and clears on demand"
