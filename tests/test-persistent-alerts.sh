#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"
CN="$ROOT_DIR/bin/code-notify"

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
    local subtype="$1"
    local project="$2"

    printf '{"type":"%s"}\n' "$subtype" | \
        PATH="$fake_path" \
        bash "$NOTIFIER" notification claude "$project"
}

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin" "$log_dir"

os_name="$(uname -s)"
case "$os_name" in
    Darwin|Linux) ;;
    *)
        echo "SKIP: unsupported OS for persistent alerts test"
        exit 0
        ;;
esac

banner_log="$log_dir/banner.log"
alerter_log="$log_dir/alerter.log"

if [[ "$os_name" == "Darwin" ]]; then
    cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$banner_log"
EOF
    cat > "$fake_bin/alerter" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$alerter_log"
EOF
else
    cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$banner_log"
EOF
fi

chmod +x "$fake_bin"/*
fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

persist_types_file="$HOME/.claude/notifications/persist-types"
persist_timeout_file="$HOME/.claude/notifications/persist-timeout"

# --- config commands manage state files ---
PATH="$fake_path" "$CN" alerts persist add permission_prompt >/dev/null
grep -q "permission_prompt" "$persist_types_file" || fail "persist add should write the type"

PATH="$fake_path" "$CN" alerts persist add stop >/dev/null
grep -q "permission_prompt|stop" "$persist_types_file" || fail "persist add should append types"

PATH="$fake_path" "$CN" alerts persist remove stop >/dev/null
grep -q "stop" "$persist_types_file" && fail "persist remove should drop the type"

if PATH="$fake_path" "$CN" alerts persist add not_a_type >/dev/null 2>&1; then
    fail "unknown persist types should be rejected"
fi

PATH="$fake_path" "$CN" alerts persist timeout 2h >/dev/null
[[ "$(head -n 1 "$persist_timeout_file")" == "7200" ]] || fail "persist timeout should store seconds"

if PATH="$fake_path" "$CN" alerts persist timeout "2 hours" >/dev/null 2>&1; then
    fail "invalid persist timeout should be rejected"
fi

status_output=$(PATH="$fake_path" "$CN" alerts persist)
printf '%s' "$status_output" | grep -q "permission_prompt" || fail "persist status should list configured types"

# --- persistent delivery (12h default after reset of timeout) ---
PATH="$fake_path" "$CN" alerts persist timeout 12h >/dev/null

if [[ "$os_name" == "Darwin" ]]; then
    # persistent subtype goes through alerter with the configured timeout
    run_notifier "permission_prompt" "persist-a"
    wait_for_lines "$alerter_log" 1 || fail "persistent alert should use alerter"
    grep -q -- "--timeout 43200" "$alerter_log" || fail "persistent alert should carry the 12h timeout"

    # non-persistent subtype still uses the normal banner
    run_notifier "idle_prompt" "persist-b"
    wait_for_lines "$banner_log" 1 || fail "non-persistent alert should use terminal-notifier"

    # timeout 0 = stay until manually closed (no --timeout flag)
    PATH="$fake_path" "$CN" alerts persist timeout 0 >/dev/null
    run_notifier "permission_prompt" "persist-c"
    wait_for_lines "$alerter_log" 2 || fail "persistent alert should use alerter for timeout 0"
    [[ $(grep -c -- "--timeout" "$alerter_log") -eq 1 ]] || fail "timeout 0 should omit the alerter --timeout flag"

    # removing the type goes back to normal banners
    PATH="$fake_path" "$CN" alerts persist remove permission_prompt >/dev/null
    run_notifier "permission_prompt" "persist-d"
    wait_for_lines "$banner_log" 2 || fail "removed persist type should go back to banners"
else
    # persistent subtype is sent with critical urgency and the timeout cap
    run_notifier "permission_prompt" "persist-a"
    wait_for_lines "$banner_log" 1 || fail "persistent alert was not delivered"
    grep -q -- "--urgency=critical" "$banner_log" || fail "persistent alert should use critical urgency"
    grep -q -- "--expire-time=43200000" "$banner_log" || fail "persistent alert should carry the 12h expire time"

    # non-persistent subtype keeps normal urgency
    run_notifier "idle_prompt" "persist-b"
    wait_for_lines "$banner_log" 2 || fail "non-persistent alert was not delivered"
    tail -n 1 "$banner_log" | grep -q -- "--urgency=normal" || fail "non-persistent alert should keep normal urgency"

    # removing the type goes back to normal urgency
    PATH="$fake_path" "$CN" alerts persist remove permission_prompt >/dev/null
    run_notifier "permission_prompt" "persist-c"
    wait_for_lines "$banner_log" 3 || fail "removed persist type was not delivered"
    tail -n 1 "$banner_log" | grep -q -- "--urgency=normal" || fail "removed persist type should go back to normal urgency"
fi

# --- reset clears everything ---
PATH="$fake_path" "$CN" alerts persist reset >/dev/null
[[ ! -f "$persist_types_file" ]] || fail "persist reset should remove the types file"
[[ ! -f "$persist_timeout_file" ]] || fail "persist reset should remove the timeout file"

pass "persistent alerts route through sticky delivery and clear on demand"
