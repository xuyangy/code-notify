#!/bin/bash

# Bulk `cn on` / `cn off` must process every tool and reach their summary line
# under `set -e` on bash 4.1+, where a failing (( )) statement exits the shell.
#
# The bulk function is called as a plain statement in a driver script run by
# the bash under test: wrapping the call in `if` or `||` would switch errexit
# off inside the function and hide exactly the exit this test looks for.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# First bash on this machine that is 4.1 or newer, or empty.
find_modern_bash() {
    local candidate
    for candidate in "$(command -v bash 2>/dev/null)" /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
        [[ -n "$candidate" ]] && [[ -x "$candidate" ]] || continue
        if "$candidate" -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1) ))' 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 0
}

MODERN_BASH="$(find_modern_bash)"
if [[ -z "$MODERN_BASH" ]]; then
    echo "SKIP: no bash 4.1+ found; the errexit behaviour under test does not exist on older bash"
    exit 0
fi

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

write_driver() {
    local driver="$1"
    local call="$2"

    # shellcheck disable=SC2016  # the driver, not this script, expands these
    {
        printf '%s\n' 'set -e'
        printf 'export HOME=%q\n' "$TEST_DIR/home"
        printf '%s\n' 'export CLAUDE_HOME="$HOME/.claude"'
        printf '%s\n' 'mkdir -p "$CLAUDE_HOME/notifications"'
        printf 'source %q\n' "$LIB_DIR/utils/colors.sh"
        printf 'source %q\n' "$LIB_DIR/utils/detect.sh"
        printf 'source %q\n' "$LIB_DIR/utils/help.sh"
        printf 'source %q\n' "$LIB_DIR/core/config.sh"
        printf 'source %q\n' "$LIB_DIR/commands/global.sh"
        printf '%s\n' 'get_installed_tools() { echo "claude codex gemini"; }'
        printf '%s\n' 'is_tool_installed() { return 0; }'
        printf '%s\n' 'is_tool_enabled() { return 1; }'
        printf '%s\n' 'is_tool_disable_needed() { return 0; }'
        printf '%s\n' 'enable_tool() { echo "$1" >> "$HOME/enabled-tools"; return 0; }'
        printf '%s\n' 'disable_tool() { echo "$1" >> "$HOME/disabled-tools"; return 0; }'
        printf '%s\n' 'test_notification() { return 0; }'
        printf '%s\n' "$call"
    } > "$driver"
}

mkdir -p "$TEST_DIR/home"

write_driver "$TEST_DIR/on.sh" 'enable_notifications_global all'
on_status=0
on_output="$("$MODERN_BASH" "$TEST_DIR/on.sh" 2>&1 < /dev/null)" || on_status=$?
[[ "$on_status" -eq 0 ]] || fail "bulk cn on exited $on_status under $MODERN_BASH: $on_output"
enabled_tools="$(sort "$TEST_DIR/home/enabled-tools" | tr '\n' ' ')"
[[ "$enabled_tools" == "claude codex gemini " ]] || fail "bulk cn on enabled only: $enabled_tools"
[[ "$on_output" == *"Enabled notifications for 3 tool(s)"* ]] || fail "bulk cn on never reached its summary: $on_output"
pass "bulk cn on enables every tool and reaches its summary under set -e"

write_driver "$TEST_DIR/off.sh" 'disable_notifications_global all'
off_status=0
off_output="$("$MODERN_BASH" "$TEST_DIR/off.sh" 2>&1 < /dev/null)" || off_status=$?
[[ "$off_status" -eq 0 ]] || fail "bulk cn off exited $off_status under $MODERN_BASH: $off_output"
disabled_tools="$(sort "$TEST_DIR/home/disabled-tools" | tr '\n' ' ')"
[[ "$disabled_tools" == "antigravity claude codex gemini omp opencode pi " ]] || fail "bulk cn off disabled only: $disabled_tools"
[[ "$off_output" == *"Disabled notifications for 7 tool(s)"* ]] || fail "bulk cn off never reached its summary: $off_output"
pass "bulk cn off disables every tool and reaches its summary under set -e"
