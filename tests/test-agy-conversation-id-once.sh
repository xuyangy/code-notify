#!/bin/bash

# Antigravity's silent events (PreInvocation before every model call,
# PreToolUse/PostToolUse around every tool call) look up two or three
# per-conversation state files each. The conversation id must be extracted
# from the payload once per hook run, not once per state file, and the state
# files must keep their per-conversation names.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

REAL_JQ="$(command -v jq || true)"
if [[ -z "$REAL_JQ" ]]; then
    echo "SKIP: jq not available"
    exit 0
fi

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.claude/notifications" "$TEST_DIR/bin"
jq_log="$TEST_DIR/jq.calls"

# Logs each jq start with its arguments, then runs the real jq.
cat > "$TEST_DIR/bin/jq" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$jq_log"
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$TEST_DIR/bin/jq"

run_agy() {
    local event="$1" payload="$2"
    rm -f "$jq_log"
    printf '%s' "$payload" | env -u TMUX -u TMUX_PANE \
        PATH="$TEST_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        CODE_NOTIFY_TAIL_SYNC=1 \
        bash "$NOTIFIER" "agy:$event" antigravity
}

cid_lookups() { grep -c 'conversationId' "$jq_log" 2>/dev/null || true; }

payload='{"conversationId":"conv/1 x","workspacePaths":["/tmp/work/proj"]}'

run_agy PreInvocation "$payload"
[[ "$(cid_lookups)" == "1" ]] || fail "PreInvocation extracted the conversation id $(cid_lookups) times"
[[ -f "$HOME/.claude/notifications/agy/conv_1_x.running" ]] \
    || fail "PreInvocation did not write the per-conversation running marker"
pass "PreInvocation extracts the conversation id once and keeps the state file name"

run_agy PostToolUse '{"conversationId":"conv/1 x","toolCall":{"name":"view_file"},"workspacePaths":["/tmp/work/proj"]}'
[[ "$(cid_lookups)" == "1" ]] || fail "PostToolUse extracted the conversation id $(cid_lookups) times"
pass "PostToolUse extracts the conversation id once"
