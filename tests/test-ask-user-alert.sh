#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export CLAUDE_HOME="$HOME/.claude"
export CLAUDE_SETTINGS_HOME="$CLAUDE_HOME"
mkdir -p "$CLAUDE_HOME/notifications"

source "$ROOT_DIR/lib/code-notify/core/config.sh"

notify_script="$test_dir/notify.sh"
get_notify_script() {
    printf '%s\n' "$notify_script"
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

cat > "$GLOBAL_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "echo custom ask-user hook"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo custom bash hook"
          }
        ]
      }
    ]
  }
}
JSON

set_notify_types "idle_prompt|ask_user"
enable_hooks_in_settings
enable_hooks_in_settings

python3 - "$GLOBAL_SETTINGS_FILE" "$notify_script" <<'PYTHON'
import json
import sys

settings_file, notify_script = sys.argv[1:3]
with open(settings_file, "r") as fh:
    hooks = json.load(fh).get("hooks", {})

pre_tool = hooks.get("PreToolUse", [])
ask_entries = [entry for entry in pre_tool if entry.get("matcher") == "AskUserQuestion"]
bash_entries = [entry for entry in pre_tool if entry.get("matcher") == "Bash"]
managed_command = f"{notify_script} PreToolUse claude"

if not any(
    hook.get("command") == "echo custom ask-user hook"
    for entry in ask_entries
    for hook in entry.get("hooks", [])
):
    raise SystemExit("custom AskUserQuestion hook was not preserved")

managed_count = sum(
    1
    for entry in ask_entries
    for hook in entry.get("hooks", [])
    if hook.get("command") == managed_command
)
if managed_count != 1:
    raise SystemExit(f"expected one managed AskUserQuestion hook, found {managed_count}")

if not any(
    hook.get("command") == "echo custom bash hook"
    for entry in bash_entries
    for hook in entry.get("hooks", [])
):
    raise SystemExit("custom non-AskUserQuestion PreToolUse hook was not preserved")
PYTHON

unregister_ask_user_hook "$GLOBAL_SETTINGS_FILE" "$(get_global_claude_pre_tool_use_command)"

python3 - "$GLOBAL_SETTINGS_FILE" "$notify_script" <<'PYTHON'
import json
import sys

settings_file, notify_script = sys.argv[1:3]
with open(settings_file, "r") as fh:
    hooks = json.load(fh).get("hooks", {})

managed_command = f"{notify_script} PreToolUse claude"
pre_tool = hooks.get("PreToolUse", [])

if any(
    hook.get("command") == managed_command
    for entry in pre_tool
    for hook in entry.get("hooks", [])
):
    raise SystemExit("managed AskUserQuestion hook was not removed")

if not any(
    entry.get("matcher") == "AskUserQuestion" and
    any(hook.get("command") == "echo custom ask-user hook" for hook in entry.get("hooks", []))
    for entry in pre_tool
):
    raise SystemExit("custom AskUserQuestion hook was removed")

if not any(
    entry.get("matcher") == "Bash" and
    any(hook.get("command") == "echo custom bash hook" for hook in entry.get("hooks", []))
    for entry in pre_tool
):
    raise SystemExit("custom Bash hook was removed")
PYTHON

# Runtime regression: Claude follows an AskUserQuestion PreToolUse event with a
# generic permission_prompt Notification for the same question UI. The latter
# must not replace the specific question alert. Correlation is session-scoped
# and one-shot so genuine approvals still get through.
notifier="$ROOT_DIR/lib/code-notify/core/notifier.sh"
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
mkdir -p "$fake_bin" "$log_dir" "$CLAUDE_HOME/logs"

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
        echo "SKIP: unsupported OS for ask_user delivery test"
        echo "PASS: ask_user alert preserves custom PreToolUse hooks"
        exit 0
        ;;
esac
chmod +x "$fake_bin"/*
fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

run_notifier() {
    local hook_type="$1" payload="$2"
    printf '%s\n' "$payload" | env -u TMUX -u TMUX_PANE \
        PATH="$fake_path" \
        CODE_NOTIFY_TAIL_SYNC=1 \
        bash "$notifier" "$hook_type" claude test-project
}

line_count() {
    if [[ -f "$notification_log" ]]; then
        wc -l < "$notification_log" | tr -d ' '
    else
        printf '%s\n' 0
    fi
}

question_payload() {
    local session_id="$1" question="$2"
    printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"tool-question","tool_input":{"questions":[{"question":"%s"}]}}' \
        "$session_id" "$question"
}

permission_payload() {
    local session_id="$1"
    printf '{"session_id":"%s","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}' \
        "$session_id"
}

run_notifier PreToolUse "$(question_payload session-a 'Which database should I use?')"
[[ "$(line_count)" == "1" ]] || fail "question notification was not delivered"
grep -q "Which database should I use?" "$notification_log" ||
    fail "question text was missing from the notification"

run_notifier notification "$(permission_payload session-a)"
[[ "$(line_count)" == "1" ]] ||
    fail "same-session permission duplicate replaced the question notification"

# The marker is consumed, so a real subsequent approval in the same session
# must not be hidden.
run_notifier notification "$(permission_payload session-a)"
[[ "$(line_count)" == "2" ]] ||
    fail "a later same-session permission request was suppressed"

# A question in one Claude session must not suppress another session's real
# approval request; its own immediate duplicate is still discarded afterward.
run_notifier PreToolUse "$(question_payload session-b 'Which API should I call?')"
run_notifier notification "$(permission_payload session-c)"
[[ "$(line_count)" == "4" ]] ||
    fail "cross-session permission request was suppressed"
run_notifier notification "$(permission_payload session-b)"
[[ "$(line_count)" == "4" ]] ||
    fail "second question's permission duplicate was delivered"

echo "PASS: ask_user alert preserves hooks and suppresses only its duplicate permission notification"
