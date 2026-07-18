#!/bin/bash
#
# StopFailure is Claude Code's "turn ended on an API error" event — the only
# signal sent when the usage limit kills a running task ("stop and wait"), so
# without it the tmux running indicator keeps spinning. Covers the managed
# hook round-trip (enable installs it, disable removes it, user hooks survive)
# and the notifier's classification: rate_limit gets the ⏳ Limit Reached
# treatment, every other error class folds into the 🧨 error path.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

run_config_case() {
    local label="$1" force_python="$2"
    local test_dir
    test_dir="$(mktemp -d)"

    export HOME="$test_dir/home"
    export CLAUDE_HOME="$HOME/.claude"
    export CLAUDE_SETTINGS_HOME="$CLAUDE_HOME"
    mkdir -p "$CLAUDE_HOME/notifications"

    # shellcheck disable=SC1091
    source "$ROOT_DIR/lib/code-notify/core/config.sh"
    local notify_script="$test_dir/notify.sh"
    get_notify_script() { printf '%s\n' "$notify_script"; }
    if [[ "$force_python" == "1" ]]; then
        if ! command -v python3 > /dev/null 2>&1; then
            echo "SKIP [$label]: python3 not available"
            rm -rf "$test_dir"
            return 0
        fi
        has_jq() { return 1; }   # force the python3 backend
    fi

    local sf="$GLOBAL_SETTINGS_FILE"
    local expect="$notify_script StopFailure claude"

    # A pre-existing USER StopFailure hook that must survive enable/disable.
    mkdir -p "$(dirname "$sf")"
    cat > "$sf" <<'JSON'
{ "hooks": { "StopFailure": [ { "matcher": "", "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }
JSON

    enable_hooks_in_settings > /dev/null
    enable_hooks_in_settings > /dev/null   # twice: must stay idempotent

    python3 - "$sf" "$expect" <<'PY' || fail "[$label] enable state wrong"
import json, sys
sf, expect = sys.argv[1:3]
h = json.load(open(sf))["hooks"]
cmds = [k.get("command") for e in h.get("StopFailure", []) for k in e.get("hooks", [])]
assert cmds.count(expect) == 1, f"expected exactly one managed StopFailure hook, got {cmds}"
assert "echo mine" in cmds, f"user hook lost: {cmds}"
PY

    disable_hooks_in_settings > /dev/null

    python3 - "$sf" "$expect" <<'PY' || fail "[$label] disable state wrong"
import json, os, sys
sf, expect = sys.argv[1:3]
assert os.path.exists(sf), "file should remain while the user hook is present"
h = json.load(open(sf)).get("hooks", {})
cmds = [k.get("command") for e in h.get("StopFailure", []) for k in e.get("hooks", [])]
assert expect not in cmds, f"managed hook not removed: {cmds}"
assert "echo mine" in cmds, f"user hook lost on disable: {cmds}"
PY

    echo "PASS: StopFailure hook round-trip [$label]"
    rm -rf "$test_dir"
}

# Feed the notifier a StopFailure payload and capture the toast the fake
# terminal-notifier receives.
run_notifier_case() {
    local label="$1" payload="$2" want="$3" reject="$4"
    local test_dir fake_bin log_dir
    test_dir="$(mktemp -d)"

    export HOME="$test_dir/home"
    fake_bin="$test_dir/bin"
    log_dir="$test_dir/log"
    mkdir -p "$HOME/.claude/notifications" "$fake_bin" "$log_dir"

    cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then exit 0; fi
printf '%s\n' "\$@" >> "$log_dir/terminal-notifier.log"
EOF
    chmod +x "$fake_bin/terminal-notifier"

    printf '%s' "$payload" |
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" bash "$NOTIFIER" StopFailure claude project

    local tries=0
    while [[ ! -f "$log_dir/terminal-notifier.log" ]] && (( tries++ < 40 )); do
        sleep 0.05
    done
    [[ -f "$log_dir/terminal-notifier.log" ]] || fail "$label: no notification sent"
    grep -q "$want" "$log_dir/terminal-notifier.log" ||
        fail "$label: expected '$want' in toast, got: $(tr '\n' ' ' < "$log_dir/terminal-notifier.log")"
    if grep -q "$reject" "$log_dir/terminal-notifier.log"; then
        fail "$label: unexpected '$reject' in toast"
    fi

    echo "PASS: StopFailure notifier classification [$label]"
    rm -rf "$test_dir"
}

run_config_case "jq" 0
run_config_case "python" 1

if [[ "$(uname -s)" == "Darwin" ]]; then
    run_notifier_case "rate_limit" \
        '{"hook_event_name":"StopFailure","error":"rate_limit"}' \
        "Limit Reached" "Error"
    run_notifier_case "server_error" \
        '{"hook_event_name":"StopFailure","error":"server_error"}' \
        "Error" "Limit Reached"
    # Only the structured "error" field may classify: a failure whose free-form
    # details merely mention rate_limit must stay a plain error.
    run_notifier_case "details-mention-rate-limit" \
        '{"hook_event_name":"StopFailure","error":"server_error","error_details":"upstream said rate_limit"}' \
        "Error" "Limit Reached"
else
    echo "SKIP: notifier classification cases are macOS-specific"
fi

echo "All StopFailure hook tests passed"
