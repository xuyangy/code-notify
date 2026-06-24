#!/bin/bash

# Antigravity (agy) hooks.json must survive spaces in the staging/HOME path.
# agy runs each hook "command" through a shell, so an unquoted path with spaces
# word-splits and the hook fails (exit 127 / command not found). code-notify
# single-quotes the wrapper path inside the JSON command string; this test
# generates the file under a spaced path and confirms it is valid JSON AND that
# the command actually executes the wrapper.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Need a JSON parser to assert the generated file is valid and to read the
# command exactly as agy would.
if command -v jq >/dev/null 2>&1; then
    read_command() { jq -r '."code-notify".PostToolUse[0].hooks[0].command' "$1"; }
    valid_json() { jq -e . "$1" >/dev/null 2>&1; }
elif command -v python3 >/dev/null 2>&1; then
    read_command() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['code-notify']['PostToolUse'][0]['hooks'][0]['command'])" "$1"; }
    valid_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" >/dev/null 2>&1; }
else
    echo "SKIP: jq or python3 required for Antigravity spaces test"
    exit 0
fi

base="$(mktemp -d)"
trap 'rm -rf "$base"' EXIT

# A HOME with a space — the reported failure case.
export HOME="$base/My Home Dir"
mkdir -p "$HOME/.claude/notifications" "$HOME/.gemini/config"

cat > "$HOME/.claude/notifications/notify.sh" <<'EOS'
#!/bin/bash
echo "ran $*" > "$HOME/hook-marker"
EOS
chmod +x "$HOME/.claude/notifications/notify.sh"

source "$ROOT_DIR/lib/code-notify/utils/colors.sh" 2>/dev/null
source "$ROOT_DIR/lib/code-notify/core/config.sh"
get_notify_script() { echo "$HOME/.claude/notifications/notify.sh"; }

notify_script="$(get_notify_script)"
staging="$ANTIGRAVITY_PLUGIN_STAGING"
mkdir -p "$staging/hooks"
write_agy_hook_wrapper "$staging/hooks/posttooluse.sh" "PostToolUse" "$notify_script"

cat > "$staging/hooks.json" <<EOF
{ "code-notify": { "PostToolUse": [ { "matcher": "", "hooks": [ { "type": "command", "command": "$(agy_shell_quote "$staging/hooks/posttooluse.sh")" } ] } ] } }
EOF

valid_json "$staging/hooks.json" || fail "generated hooks.json is not valid JSON under a spaced path"

cmd="$(read_command "$staging/hooks.json")"
[[ -n "$cmd" ]] || fail "could not read the hook command from hooks.json"

# Execute exactly how agy does (command string via a shell). With the path
# unquoted this fails with 127; quoted, it runs the wrapper.
/bin/sh -c "$cmd" </dev/null || fail "hook command failed to execute under a spaced path (exit $?)"

[[ -f "$HOME/hook-marker" ]] || fail "wrapper did not run — command word-split on the spaced path"
grep -q "ran agy:PostToolUse antigravity" "$HOME/hook-marker" \
    || fail "wrapper ran but with unexpected arguments: $(cat "$HOME/hook-marker")"

pass "Antigravity hook commands survive spaces in the staging/HOME path"
