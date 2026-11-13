#!/bin/bash

# Gemini settings can hold the user's own Notification/AfterAgent hooks.
# code-notify must recognise only its own hooks (by command, not by event key
# or hook name), add and remove only those, keep hooks.enabled while user
# hooks remain, and write the same file on a second `cn on gemini`. Checked
# with jq and with the python3 fallback.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# $1: "jq" or "python3" — which JSON tool config.sh may use.
run_case() {
    local tool="$1"
    (
        export HOME="$TEST_DIR/home-$tool"
        # Never let an inherited GEMINI_HOME point the test at a real config.
        unset GEMINI_HOME
        mkdir -p "$HOME/.gemini"
        source "$LIB_DIR/core/config.sh"
        if [[ "$tool" == "python3" ]]; then
            has_jq() { return 1; }
        fi
        notify_script="$TEST_DIR/code-notify/notifier.sh"
        get_notify_script() { printf '%s\n' "$notify_script"; }
        settings="$GEMINI_SETTINGS_FILE"

        # A user hook that only QUOTES a managed-looking command in another
        # field is not code-notify's: ownership is by the command string.
        cat > "$settings" <<JSON
{
  "hooks": {
    "AfterAgent": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/usr/local/bin/my-logger",
        "description": "example: /old/code-notify/lib/code-notify/core/notifier.sh stop gemini" } ] }
    ]
  }
}
JSON
        if is_gemini_enabled; then
            fail "$tool: a user hook quoting a managed command in its description read as enabled"
        fi

        # A user hook under AfterAgent, hooks.enabled set by the user, and a
        # stale code-notify hook sharing an entry with a user hook.
        cat > "$settings" <<JSON
{
  "theme": "x",
  "hooks": {
    "enabled": true,
    "AfterAgent": [
      { "matcher": "", "hooks": [ { "name": "code-notify-complete", "type": "command", "command": "/usr/local/bin/my-logger" } ] }
    ],
    "Notification": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "/usr/local/bin/my-pager" },
        { "type": "command", "command": "/old/code-notify/lib/code-notify/core/notifier.sh notification gemini" }
      ] }
    ]
  }
}
JSON
        hook_commands() {
            python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for event, entries in sorted((data.get("hooks") or {}).items()):
    if isinstance(entries, list):
        for entry in entries:
            for hook in entry.get("hooks", []):
                print(event, hook.get("command"))
' "$settings"
        }

        # The stale hook makes it look enabled; the user hooks alone would not.
        is_gemini_enabled || fail "$tool: a code-notify hook in settings was not recognised"

        enable_gemini_hooks >/dev/null 2>&1 || fail "$tool: enable_gemini_hooks failed"
        commands="$(hook_commands)"
        [[ "$commands" == *"AfterAgent /usr/local/bin/my-logger"* ]] || fail "$tool: enable removed the user's AfterAgent hook"
        [[ "$commands" == *"Notification /usr/local/bin/my-pager"* ]] || fail "$tool: enable removed the user's hook sharing an entry with a stale one"
        [[ "$commands" != *"/old/code-notify"* ]] || fail "$tool: enable kept the stale code-notify hook"
        [[ "$commands" == *"AfterAgent $notify_script stop gemini"* ]] || fail "$tool: enable did not add the AfterAgent hook"
        [[ "$commands" == *"Notification $notify_script notification gemini"* ]] || fail "$tool: enable did not add the Notification hook"
        is_gemini_enabled || fail "$tool: enabled settings did not read as enabled"

        before="$(cat "$settings")"
        enable_gemini_hooks >/dev/null 2>&1 || fail "$tool: second enable_gemini_hooks failed"
        [[ "$(cat "$settings")" == "$before" ]] || fail "$tool: a second enable changed the settings"

        disable_gemini_hooks >/dev/null 2>&1 || fail "$tool: disable_gemini_hooks failed"
        commands="$(hook_commands)"
        [[ "$commands" == *"AfterAgent /usr/local/bin/my-logger"* ]] || fail "$tool: disable removed the user's AfterAgent hook"
        [[ "$commands" == *"Notification /usr/local/bin/my-pager"* ]] || fail "$tool: disable removed the user's Notification hook"
        [[ "$commands" != *"gemini"* ]] || fail "$tool: disable left a code-notify hook"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["hooks"].get("enabled") is True and d.get("theme") == "x" else 1)' "$settings" \
            || fail "$tool: disable dropped hooks.enabled or other settings while user hooks remain"
        if is_gemini_enabled; then
            fail "$tool: user hooks alone read as code-notify enabled"
        fi

        # With only code-notify's hooks, disable removes the hooks object
        # entirely, as before.
        rm -f "$settings"
        enable_gemini_hooks >/dev/null 2>&1 || fail "$tool: enable on a fresh file failed"
        disable_gemini_hooks >/dev/null 2>&1 || fail "$tool: disable on a fresh file failed"
        if [[ -f "$settings" ]] && python3 -c 'import json,sys; sys.exit(0 if "hooks" in json.load(open(sys.argv[1])) else 1)' "$settings"; then
            fail "$tool: disable left a hooks object when only code-notify hooks existed"
        fi
    ) < /dev/null
    pass "Gemini ($tool): user hooks and hooks.enabled survive; code-notify hooks are added once and removed"
}

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 is needed to inspect the settings"
    exit 0
fi
if command -v jq >/dev/null 2>&1; then
    run_case jq
fi
run_case python3
