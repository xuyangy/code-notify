#!/bin/bash

# `cnp voice <subcommand>` must reach the voice handler with its subcommand:
# `cnp voice off` removes the project voice, and a bare `cnp voice` shows the
# status instead of exiting with an error.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/../bin/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
project="$TEST_DIR/my-project"
mkdir -p "$HOME/.claude/notifications" "$project/.claude"
git -C "$project" init -q

run_cli() {
    (builtin cd "$project" && "$CLI" project voice "$@" < /dev/null 2>&1)
}

status=0
output="$(run_cli)" || status=$?
[[ "$status" -eq 0 ]] || fail "cnp voice exited $status: $output"
[[ "$output" == *"Project voice"* ]] || fail "cnp voice did not show the project voice status: $output"
pass "bare cnp voice shows the status"

printf '%s\n' "Daniel" > "$project/.claude/voice"
status=0
output="$(run_cli off)" || status=$?
[[ "$status" -eq 0 ]] || fail "cnp voice off exited $status: $output"
[[ ! -e "$project/.claude/voice" ]] || fail "cnp voice off left the project voice in place: $output"
pass "cnp voice off removes the project voice"
