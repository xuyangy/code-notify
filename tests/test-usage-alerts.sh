#!/bin/bash

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
quota_count="$test_dir/quota-count"
curl_log="$test_dir/curl.log"
notify_log="$test_dir/notify.log"
say_log="$test_dir/say.log"
mkdir -p "$HOME/.codex" "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin"

printf '{"tokens":{"access_token":"codex-token"}}' > "$HOME/.codex/auth.json"
printf '0' > "$quota_count"

case "$(uname -s)" in
    Darwin)
        notifier_name="terminal-notifier"
        expect_voice=true
        ;;
    Linux)
        notifier_name="notify-send"
        expect_voice=false
        ;;
    *)
        echo "SKIP: unsupported OS for usage alert test"
        exit 0
        ;;
esac

cat > "$fake_bin/$notifier_name" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notify_log"
EOF

cat > "$fake_bin/say" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$say_log"
EOF

cat > "$fake_bin/curl" <<EOF
#!/bin/bash
last_arg="\${@: -1}"
if [[ "\$last_arg" == *"wham/usage"* ]]; then
    count=\$(cat "$quota_count")
    count=\$((count + 1))
    printf '%s' "\$count" > "$quota_count"
    case "\$count" in
        1) used=5 ;;
        2) used=80 ;;
        3) used=91 ;;
        4) used=91 ;;
        5) used=70 ;;
        6) used=91 ;;
        7) used=50 ;;
        8) used=0 ;;
        9) used=0 ;;
        10) used=10 ;;
        *) used=0 ;;
    esac
    printf '{"rate_limit":{"primary_window":{"used_percent":%s,"reset_at":1900000000},"secondary_window":{"used_percent":50,"reset_at":1900000000}}}' "\$used"
    exit 0
fi
printf '%s\n' "\$*" >> "$curl_log"
exit 0
EOF
chmod +x "$fake_bin"/*

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" channels add slack "https://hooks.slack.com/services/T000/B000/SECRET" >/dev/null
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" usage on codex >/dev/null
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" usage reset-alerts voice off >/dev/null
reset_status=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT_DIR/bin/code-notify" usage status)
printf '%s' "$reset_status" | grep -q "Reset voice: .*DISABLED" || fail "reset voice should be configurable separately"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" usage reset-alerts voice on >/dev/null

run_check() {
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$ROOT_DIR/bin/code-notify" usage check codex >/dev/null
}

run_check
[[ ! -s "$notify_log" ]] || fail "95 percent remaining should not alert"

run_check
grep -q "daily (5h) remaining usage is 20%" "$notify_log" || fail "20 percent threshold alert missing"
first_count=$(wc -l < "$notify_log")

run_check
grep -q "daily (5h) remaining usage is 9%" "$notify_log" || fail "10 percent threshold alert missing"
second_count=$(wc -l < "$notify_log")
[[ "$second_count" -gt "$first_count" ]] || fail "10 percent alert did not add a notification"

run_check
third_count=$(wc -l < "$notify_log")
[[ "$third_count" -eq "$second_count" ]] || fail "repeated 9 percent should not duplicate"

run_check
run_check
repeat_count=$(wc -l < "$notify_log")
[[ "$repeat_count" -gt "$third_count" ]] || fail "threshold alert should re-arm after recovery"

run_check
before_reset_count=$(wc -l < "$notify_log")
run_check
grep -q "token daily limit reset" "$notify_log" || fail "reset alert title should identify the limit window"
grep -q "daily (5h) tokens have reset" "$notify_log" || fail "reset alert message should mention tokens"
after_reset_count=$(wc -l < "$notify_log")
[[ "$after_reset_count" -gt "$before_reset_count" ]] || fail "reset alert did not add a notification"

run_check
same_reset_count=$(wc -l < "$notify_log")
[[ "$same_reset_count" -eq "$after_reset_count" ]] || fail "repeated 100 percent should not duplicate"

run_check
run_check
refill_count=$(grep -c "tokens have reset" "$notify_log")
[[ "$refill_count" -ge 2 ]] || fail "reset alert should re-arm after usage drops"

grep -q "hooks.slack.com/services/T000/B000/SECRET" "$curl_log" || fail "usage alert should deliver to Slack channel"
if [[ "$expect_voice" == "true" ]]; then
    for _ in $(seq 1 40); do
        [[ -f "$say_log" ]] && [[ $(wc -l < "$say_log") -ge 2 ]] && break
        sleep 0.05
    done
    [[ -f "$say_log" ]] && [[ $(wc -l < "$say_log") -ge 2 ]] \
        || fail "reset voice should play for both reset transitions"
    grep -q "token daily limit reset" "$say_log" \
        || fail "reset voice should use the dedicated reset message"
fi

: > "$notify_log"
: > "$say_log"
printf '7' > "$quota_count"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" usage reset-state >/dev/null
run_check
[[ ! -s "$notify_log" ]] || fail "first observation at 100 percent should not emit reset notification"
[[ ! -s "$say_log" ]] || fail "first observation at 100 percent should not speak reset voice"

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" usage reset-alerts off >/dev/null
disabled_reset_status=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT_DIR/bin/code-notify" usage status)
printf '%s' "$disabled_reset_status" | grep -q "Reset alerts: .*DISABLED" || fail "reset alerts should be optional"

watch_home="$test_dir/watch-home"
mkdir -p "$watch_home/.codex"
printf '{"tokens":{"access_token":"codex-token"}}' > "$watch_home/.codex/auth.json"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$watch_home" \
    "$ROOT_DIR/bin/code-notify" usage setup codex --watch --interval 60 >/dev/null
watch_status=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$watch_home" "$ROOT_DIR/bin/code-notify" usage status)
printf '%s' "$watch_status" | grep -q "Watcher: .*RUNNING" || fail "setup --watch should start background watcher"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$watch_home" \
    "$ROOT_DIR/bin/code-notify" usage watch stop >/dev/null
stopped_status=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$watch_home" "$ROOT_DIR/bin/code-notify" usage watch status)
printf '%s' "$stopped_status" | grep -q "Watcher: .*STOPPED" || fail "usage watcher should stop cleanly"

pass "usage alerts detect Codex thresholds and reset transitions without duplicates"
