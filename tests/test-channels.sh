#!/bin/bash

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
curl_log="$test_dir/curl.log"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin"

cat > "$fake_bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$curl_log"
exit 0
EOF
chmod +x "$fake_bin/curl"

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" channels add slack "https://hooks.slack.com/services/T000/B000/SECRET" --name team >/dev/null
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" channels add discord "https://discord.com/api/webhooks/123/SECRET" --name chat >/dev/null
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" channels add ntfy "https://ntfy.sh/private-topic" --name phone >/dev/null

# ntfy URLs must be https and carry a topic segment
if PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" channels add ntfy "http://ntfy.sh/topic" >/dev/null 2>&1; then
    fail "plain-http ntfy URL should be rejected"
fi
if PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" channels add ntfy "https://ntfy.sh/" >/dev/null 2>&1; then
    fail "ntfy URL without a topic should be rejected"
fi

status_output=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT_DIR/bin/code-notify" channels status)
printf '%s' "$status_output" | grep -q "hooks.slack.com" || fail "Slack host should be shown"
printf '%s' "$status_output" | grep -q "discord.com" || fail "Discord host should be shown"
printf '%s' "$status_output" | grep -q "ntfy.sh" || fail "ntfy host should be shown"
if printf '%s' "$status_output" | grep -q "SECRET"; then
    fail "status output leaked webhook token"
fi

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" channels test all >/dev/null

grep -q "hooks.slack.com/services/T000/B000/SECRET" "$curl_log" || fail "Slack webhook was not called"
grep -q "discord.com/api/webhooks/123/SECRET" "$curl_log" || fail "Discord webhook was not called"
grep -q '"text"' "$curl_log" || fail "Slack payload should use text"
grep -q '"content"' "$curl_log" || fail "Discord payload should use content"
grep -q '"allowed_mentions"' "$curl_log" || fail "Discord payload should disable mentions"
grep -q "ntfy.sh/private-topic" "$curl_log" || fail "ntfy endpoint was not called"
grep -q -- "-H Title: Code-Notify Test" "$curl_log" || fail "ntfy should send the title as a header"
if grep "ntfy.sh/private-topic" "$curl_log" | grep -q "Content-Type: application/json"; then
    fail "ntfy should send a plain-text body, not JSON"
fi

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" channels off >/dev/null
: > "$curl_log"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" channels test all >/dev/null 2>&1 && fail "disabled channels should not send test messages"
[[ ! -s "$curl_log" ]] || fail "disabled channels should not call webhooks"

pass "channels store redacted Slack/Discord/ntfy endpoints and deliver provider payloads"
