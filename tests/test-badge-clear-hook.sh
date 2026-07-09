#!/bin/bash
#
# The UserPromptSubmit "badge-clear" hook is code-notify's engage-clear signal
# for Claude: enable installs it, disable removes it, and both must preserve a
# user's own UserPromptSubmit hook. Exercised over the jq and python3 config
# backends so neither path regresses.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

run_case() {
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
    local expect="$notify_script UserPromptSubmit claude"

    # A pre-existing USER UserPromptSubmit hook that must survive enable/disable.
    mkdir -p "$(dirname "$sf")"
    cat > "$sf" <<'JSON'
{ "hooks": { "UserPromptSubmit": [ { "matcher": "", "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }
JSON

    enable_hooks_in_settings > /dev/null
    enable_hooks_in_settings > /dev/null   # twice: must stay idempotent

    python3 - "$sf" "$expect" "$notify_script" <<'PY' || fail "[$label] enable state wrong"
import json, sys
sf, expect, script = sys.argv[1:4]
h = json.load(open(sf))["hooks"]
cmds = [k.get("command") for e in h.get("UserPromptSubmit", []) for k in e.get("hooks", [])]
assert cmds.count(expect) == 1, f"expected exactly one managed hook, got {cmds}"
assert "echo mine" in cmds, f"user hook lost: {cmds}"
assert any(k.get("command") == f"{script} stop claude"
           for e in h.get("Stop", []) for k in e.get("hooks", [])), "Stop hook missing"
PY

    disable_hooks_in_settings > /dev/null

    python3 - "$sf" "$expect" <<'PY' || fail "[$label] disable state wrong"
import json, os, sys
sf, expect = sys.argv[1:3]
assert os.path.exists(sf), "file should remain while the user hook is present"
h = json.load(open(sf)).get("hooks", {})
cmds = [k.get("command") for e in h.get("UserPromptSubmit", []) for k in e.get("hooks", [])]
assert expect not in cmds, f"managed hook not removed: {cmds}"
assert "echo mine" in cmds, f"user hook lost on disable: {cmds}"
assert "Stop" not in h, "Stop should be removed on disable"
PY

    # With no user hooks left, a clean enable/disable round-trip removes the file.
    rm -f "$sf"
    enable_hooks_in_settings > /dev/null
    disable_hooks_in_settings > /dev/null
    [[ ! -f "$sf" ]] || fail "[$label] settings file should be deleted once empty"

    echo "PASS: badge-clear hook round-trip [$label]"
    rm -rf "$test_dir"
}

run_case "jq" 0
run_case "python" 1

echo "All badge-clear hook tests passed"
