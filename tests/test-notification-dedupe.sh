#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

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
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=180 \
        bash "$NOTIFIER" notification claude test-project
}

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
sound_file="$test_dir/custom.aiff"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin" "$log_dir"

touch "$sound_file"
: > "$HOME/.claude/notifications/sound-enabled"
printf '%s\n' "$sound_file" > "$HOME/.claude/notifications/sound-custom"

case "$(uname -s)" in
    Darwin)
        notification_log="$log_dir/terminal-notifier.log"
        sound_log="$log_dir/afplay.log"
        cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then exit 0; fi
printf '%s\n' "\$*" >> "$notification_log"
EOF
        cat > "$fake_bin/afplay" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$sound_log"
EOF
        ;;
    Linux)
        notification_log="$log_dir/notify-send.log"
        sound_log="$log_dir/paplay.log"
        cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        cat > "$fake_bin/paplay" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$sound_log"
EOF
        ;;
    *)
        echo "SKIP: unsupported OS for notification dedupe test"
        exit 0
        ;;
esac

chmod +x "$fake_bin"/*

fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

run_notifier_payload() {
    local fake_path="$1"
    local payload="$2"

    printf '%s\n' "$payload" | \
        PATH="$fake_path" \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=180 \
        bash "$NOTIFIER" notification claude test-project
}

run_notifier "$fake_path" "idle_prompt"
first_notification=$(sed -n '1p' "$notification_log")
[[ "$first_notification" == *"Idle"* ]] || fail "idle_prompt notification should be labeled Idle"
[[ "$first_notification" != *"Input Required"* ]] || fail "idle_prompt notification should not be labeled Input Required"
run_notifier "$fake_path" "idle_prompt"
run_notifier "$fake_path" "permission_prompt"
run_notifier "$fake_path" "permission_prompt"
run_notifier "$fake_path" "approval_requested"
# Typed payloads whose message text merely mentions permission/approval words
# must not be classified as approval prompts, so dedupe still applies.
run_notifier_payload "$fake_path" '{"type":"status_update","message":"updated file permission flags"}'
run_notifier_payload "$fake_path" '{"type":"status_update","message":"updated file permission flags"}'
# Gemini sends capitalised types; matching must be case-insensitive and
# repeated confirmations must all be delivered.
run_notifier_payload "$fake_path" '{"notification_type":"ToolPermission","message":"Tool requires confirmation"}'
run_notifier_payload "$fake_path" '{"notification_type":"ToolPermission","message":"Tool requires confirmation"}'

wait_for_lines "$notification_log" 7 || fail "expected seven notification deliveries"

# An approval whose free text names "idle_prompt" is still an approval: it is
# labelled as one and repeats are never rate-limited as idle reminders. Typed
# payload first (the word sits in cwd), then an untyped PermissionRequest (the
# word sits in the command).
typed_idle_text='{"notification_type":"permission_prompt","message":"Claude needs your permission","cwd":"/tmp/fix-idle_prompt-rate"}'
untyped_idle_text='{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"grep -rn idle_prompt lib/"}}'
run_notifier_payload "$fake_path" "$typed_idle_text"
run_notifier_payload "$fake_path" "$typed_idle_text"
run_notifier_payload "$fake_path" "$untyped_idle_text"
run_notifier_payload "$fake_path" "$untyped_idle_text"

wait_for_lines "$notification_log" 11 || fail "approvals mentioning idle_prompt should all be delivered"
wait_for_lines "$sound_log" 11 || fail "expected eleven sound playbacks"
wait_for_lines "$HOME/.claude/logs/notifications.log" 11 || fail "expected eleven notification log entries"

if sed -n '8,11p' "$notification_log" | grep -q "Idle"; then
    fail "approval mentioning idle_prompt should not be labeled Idle"
fi

[[ $(wc -l < "$notification_log") -eq 11 ]] || fail "non-approval duplicates should be suppressed"
[[ $(wc -l < "$sound_log") -eq 11 ]] || fail "non-approval sound playback should be suppressed"
[[ $(wc -l < "$HOME/.claude/logs/notifications.log") -eq 11 ]] || fail "non-approval log entries should be suppressed"

pass "notification dedupe suppresses repeated idle_prompt events without blocking approval prompts"
