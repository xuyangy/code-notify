#!/bin/bash

# Enabling or disabling code-notify must leave a user's own hooks alone even
# when they run a script that happens to be called notify.sh. Only the legacy
# code-notify script, installed as .claude/notifications/notify.sh, counts as
# managed. Checked for Claude settings.json (jq and python3 paths) and for the
# Codex config.toml notify assignment.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# $1: "jq" or "python3" — which JSON tool config.sh may use.
run_claude_case() {
    local tool="$1"
    local home="$TEST_DIR/home-$tool"
    mkdir -p "$home/.claude/notifications" "$TEST_DIR/bin-$tool"
    (
        export HOME="$home"
        export CLAUDE_HOME="$HOME/.claude"
        export CLAUDE_SETTINGS_HOME="$CLAUDE_HOME"
        source "$LIB_DIR/core/config.sh"
        if [[ "$tool" == "python3" ]]; then
            has_jq() { return 1; }
        fi
        cat > "$GLOBAL_SETTINGS_FILE" <<JSON
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/Users/me/bin/notify.sh stop" } ] },
      { "hooks": [ { "type": "command", "command": "$HOME/.claude/notifications/notify.sh stop claude" } ] }
    ],
    "Notification": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "~/scripts/notify.sh --event notification --quiet" } ] }
    ]
  }
}
JSON
        # The user's command is the literal text "~/scripts/notify.sh ...".
        # shellcheck disable=SC2088
        user_notification='~/scripts/notify.sh --event notification --quiet'
        enable_hooks_in_settings >/dev/null 2>&1 || fail "$tool: enable_hooks_in_settings failed"
        grep -q '/Users/me/bin/notify.sh stop' "$GLOBAL_SETTINGS_FILE" \
            || fail "$tool: enabling removed a user Stop hook running notify.sh"
        grep -qF "$user_notification" "$GLOBAL_SETTINGS_FILE" \
            || fail "$tool: enabling removed a user Notification hook running notify.sh"
        if grep -q '.claude/notifications/notify.sh stop claude' "$GLOBAL_SETTINGS_FILE"; then
            fail "$tool: enabling kept the legacy code-notify notify.sh hook"
        fi

        disable_hooks_in_settings >/dev/null 2>&1 || fail "$tool: disable_hooks_in_settings failed"
        grep -q '/Users/me/bin/notify.sh stop' "$GLOBAL_SETTINGS_FILE" \
            || fail "$tool: disabling removed a user Stop hook running notify.sh"
        grep -qF "$user_notification" "$GLOBAL_SETTINGS_FILE" \
            || fail "$tool: disabling removed a user Notification hook running notify.sh"
    ) < /dev/null
    pass "Claude hooks ($tool): user notify.sh hooks survive enable and disable; the legacy hook is replaced"
}

run_claude_case jq
if command -v python3 >/dev/null 2>&1; then
    run_claude_case python3
fi

# Codex: a user notify program called notify.sh under ~/.codex is theirs.
(
    export HOME="$TEST_DIR/home-codex"
    mkdir -p "$HOME/.codex"
    source "$LIB_DIR/core/config.sh"
    config="$HOME/.codex/config.toml"
    printf '%s\n' 'model = "gpt-5"' 'notify = ["bash", "/Users/me/.codex/notify.sh"]' > "$config"
    remove_codex_notify_config "$config"
    grep -qF 'notify = ["bash", "/Users/me/.codex/notify.sh"]' "$config" \
        || fail "codex: a user notify program called notify.sh was removed"
    printf '%s\n' 'model = "gpt-5"' "notify = [\"bash\", \"$HOME/.claude/notifications/notify.sh\", \"codex\"]" > "$config"
    remove_codex_notify_config "$config"
    if grep -q '^notify' "$config"; then
        fail "codex: the legacy code-notify notify assignment was kept"
    fi
) < /dev/null
pass "Codex config.toml: a user notify.sh is kept; the legacy code-notify notify is removed"
