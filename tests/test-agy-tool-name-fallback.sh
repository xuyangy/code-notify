#!/bin/bash

# get_agy_tool_name must resolve .toolCall.name even without jq/python3 (sed
# fallback), and must never mistake a "name" key elsewhere in the payload for
# the tool name — a wrong match here mis-scopes the run_command approval
# banner. The full notifier can't run jq-less in CI, so the function is
# extracted from notifier.sh and exercised directly with the interpreter
# checks stubbed out.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

fn="$(sed -n '/^get_agy_tool_name()/,/^}/p' "$NOTIFIER")"
[[ -n "$fn" ]] || fail "could not extract get_agy_tool_name from notifier.sh"
eval "$fn"

# Force the sed fallback path.
has_jq() { return 1; }
has_python3() { return 1; }

check() {
    local desc="$1" payload="$2" expected="$3" got
    # shellcheck disable=SC2034  # read by the eval'd get_agy_tool_name
    HOOK_DATA="$payload"
    got="$(get_agy_tool_name)"
    [[ "$got" == "$expected" ]] || fail "$desc (expected '$expected', got '$got')"
    pass "$desc"
}

check "resolves toolCall.name" \
    '{"conversationId":"c1","toolCall":{"name":"run_command","command":"ls"}}' \
    "run_command"

check "ignores a top-level name key" \
    '{"name":"decoy","toolCall":{"name":"read_file"}}' \
    "read_file"

check "empty when payload has no toolCall" \
    '{"name":"decoy","conversationId":"c1"}' \
    ""

check "fails closed when name follows a nested object" \
    '{"toolCall":{"args":{"x":1},"name":"run_command"}}' \
    ""

check "tolerates whitespace around keys" \
    '{"toolCall": { "name" : "run_command" }}' \
    "run_command"

check "empty payload yields empty" \
    "" \
    ""

# Sanity: with jq available, the same payloads resolve identically (the real
# has_jq is not stubbed back in — just assert jq agrees when present).
if command -v jq >/dev/null 2>&1; then
    got="$(printf '%s' '{"name":"decoy","toolCall":{"name":"read_file"}}' | jq -r '(.toolCall.name // "")')"
    [[ "$got" == "read_file" ]] || fail "jq path disagrees with sed fallback"
    pass "jq path agrees on the decoy payload"
fi

echo "All agy tool-name fallback tests passed"
