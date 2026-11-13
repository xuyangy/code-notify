#!/bin/bash

# The global kill switch (~/.claude/notifications/disabled) mutes every tool,
# so only a bulk `cn off` may create it. A targeted `cn off <tool>` removes
# that tool's hooks and leaves the switch alone, and an unknown tool name
# changes no mute state in either direction. A targeted `cn on <tool>` for a
# known tool still clears the switch.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
export CLAUDE_HOME="$HOME/.claude"
mkdir -p "$CLAUDE_HOME/notifications"
KILL_SWITCH="$HOME/.claude/notifications/disabled"

source "$LIB_DIR/utils/colors.sh"
source "$LIB_DIR/utils/detect.sh"
source "$LIB_DIR/utils/help.sh"
source "$LIB_DIR/core/config.sh"
source "$LIB_DIR/commands/global.sh"

is_tool_installed() { return 0; }
is_tool_enabled() { return 1; }
is_tool_disable_needed() { return 0; }
enable_tool() { return 0; }
disable_tool() { return 0; }
test_notification() { return 0; }

rm -f "$KILL_SWITCH"
disable_notifications_global gemini >/dev/null 2>&1 || fail "cn off gemini failed"
[[ ! -e "$KILL_SWITCH" ]] || fail "cn off <tool> created the global kill switch"
pass "targeted cn off leaves the global kill switch alone"

disable_notifications_global typo >/dev/null 2>&1 || true
[[ ! -e "$KILL_SWITCH" ]] || fail "cn off with an unknown tool created the global kill switch"
pass "cn off with an unknown tool does not mute anything"

disable_notifications_global >/dev/null 2>&1 || fail "bulk cn off failed"
[[ -e "$KILL_SWITCH" ]] || fail "bulk cn off did not create the global kill switch"
pass "bulk cn off creates the global kill switch"

enable_notifications_global typo >/dev/null 2>&1 || true
[[ -e "$KILL_SWITCH" ]] || fail "cn on with an unknown tool cleared the global kill switch"
pass "cn on with an unknown tool does not unmute anything"

enable_notifications_global claude >/dev/null 2>&1 || fail "cn on claude failed"
[[ ! -e "$KILL_SWITCH" ]] || fail "cn on <tool> no longer clears the global kill switch"
pass "targeted cn on for a known tool clears the global kill switch"

# Bulk off must not abort when the notifications directory is missing.
rm -rf "$HOME/.claude/notifications"
disable_notifications_global >/dev/null 2>&1 || fail "bulk cn off failed without a notifications directory"
[[ -e "$KILL_SWITCH" ]] || fail "bulk cn off did not create the kill switch without a notifications directory"
pass "bulk cn off creates the notifications directory when missing"
