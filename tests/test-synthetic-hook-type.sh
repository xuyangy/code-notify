#!/bin/bash

# Antigravity exports CLAUDE_HOOK_TYPE to its hooks, and the tmux watches fork
# synthetic notifier runs from those processes. The notifier lets that
# variable override argv, so an inherited PostToolUse turns a synthetic
# approval into a silent resume hook. Every synthetic launch must clear it,
# and the notifier must read the cleared (empty) value as unset.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"
NOTIFIER="$LIB_DIR/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.claude/notifications" "$TEST_DIR/bin"
printf '%s' "idle_prompt|permission_prompt" > "$HOME/.claude/notifications/notify-types"
record="$TEST_DIR/record"

# Stub notifier: records the hook type it would see and its argv.
cat > "$TEST_DIR/stub-notifier.sh" <<EOF
#!/bin/bash
printf 'hook_type=[%s] argv=[%s]\n' "\${CLAUDE_HOOK_TYPE-unset}" "\$*" >> "$record"
cat > /dev/null
EOF

wait_for_record() {
    local want="$1"
    for _ in $(seq 1 50); do
        [[ -f "$record" ]] && [[ "$(wc -l < "$record" | tr -d ' ')" -ge "$want" ]] && return 0
        sleep 0.1
    done
    return 1
}

(
    export CLAUDE_HOOK_TYPE=PostToolUse
    export CODE_NOTIFY_NOTIFIER_PATH="$TEST_DIR/stub-notifier.sh"
    source "$LIB_DIR/utils/tmux.sh"
    tmux_idle_watch_notify "%3" antigravity proj "@2"
    tmux_dialog_watch_notify "%3" antigravity proj "@2" "1" "1" ""
    tmux_settle_watch_notify "%3" antigravity proj
    tmux_settle_watch_notify "%3" antigravity proj 1
) < /dev/null
wait_for_record 4 || fail "not every synthetic launch reached the notifier"
if grep -v '^hook_type=\[\] ' "$record"; then
    fail "a synthetic notifier launch inherited CLAUDE_HOOK_TYPE"
fi
pass "every synthetic notifier launch clears an inherited CLAUDE_HOOK_TYPE"

# The cleared value is empty, not unset; the notifier must then take its hook
# type from argv and deliver the approval.
log="$TEST_DIR/terminal-notifier.log"
cat > "$TEST_DIR/bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then exit 0; fi
printf '%s\n' "\$*" >> "$log"
EOF
cat > "$TEST_DIR/bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
EOF
chmod +x "$TEST_DIR/bin/terminal-notifier" "$TEST_DIR/bin/notify-send"
printf '%s' '{"type":"permission_prompt"}' | env -u TMUX -u TMUX_PANE \
    CLAUDE_HOOK_TYPE= \
    PATH="$TEST_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODE_NOTIFY_TAIL_SYNC=1 \
    bash "$NOTIFIER" notification antigravity proj
grep -q "Input Required" "$log" 2>/dev/null \
    || fail "an empty CLAUDE_HOOK_TYPE did not fall back to the argv hook type"
pass "an empty CLAUDE_HOOK_TYPE falls back to the argv hook type"
