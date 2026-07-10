#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

run_enable_all_alias_test() {
    local test_dir
    test_dir="$(mktemp -d)"

    (
        export HOME="$test_dir"
        export CLAUDE_HOME="$HOME/.claude"
        mkdir -p "$CLAUDE_HOME/notifications"

        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/help.sh"
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/commands/global.sh"

        get_installed_tools() { echo "claude codex gemini"; }
        is_tool_installed() { return 0; }
        is_tool_enabled() { return 1; }
        enable_tool() {
            echo "$1" >> "$HOME/enabled-tools"
            return 0
        }
        test_notification() { return 0; }

        enable_notifications_global all >/dev/null 2>&1 || fail "cn on all alias did not enable notifications"

        local enabled_tools
        enabled_tools="$(sort "$HOME/enabled-tools" | tr '\n' ' ')"
        [[ "$enabled_tools" == "claude codex gemini " ]] || fail "cn on all did not enable every detected tool"
    )

    rm -rf "$test_dir"
}

run_disable_all_alias_test() {
    local test_dir
    test_dir="$(mktemp -d)"

    (
        export HOME="$test_dir"
        export CLAUDE_HOME="$HOME/.claude"
        mkdir -p "$CLAUDE_HOME/notifications"

        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/help.sh"
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/commands/global.sh"

        is_tool_enabled() { return 0; }
        # The disable path keys on is_tool_disable_needed (antigravity reports
        # "imported" rather than "enabled"); simulate every tool needing disable.
        is_tool_disable_needed() { return 0; }
        disable_tool() {
            echo "$1" >> "$HOME/disabled-tools"
            return 0
        }

        disable_notifications_global all >/dev/null 2>&1 || fail "cn off all alias did not disable notifications"

        local disabled_tools
        disabled_tools="$(sort "$HOME/disabled-tools" | tr '\n' ' ')"
        [[ "$disabled_tools" == "antigravity claude codex gemini " ]] || fail "cn off all did not disable every enabled tool"
    )

    rm -rf "$test_dir"
}

run_status_all_alias_test() {
    local test_dir
    test_dir="$(mktemp -d)"

    (
        export HOME="$test_dir"
        export CLAUDE_HOME="$HOME/.claude"
        mkdir -p "$CLAUDE_HOME/notifications"

        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/help.sh"
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/commands/global.sh"

        is_tool_installed() { return 1; }
        is_tool_enabled() { return 1; }
        is_voice_enabled() { return 1; }
        is_sound_enabled() { return 1; }
        get_notify_types() { echo "idle_prompt"; }
        detect_os() { echo "linux"; }

        show_status all >/dev/null 2>&1 || fail "cn status all alias did not behave like cn status"
    )

    rm -rf "$test_dir"
}

run_codex_idle_messaging_test() {
    local test_dir
    test_dir="$(mktemp -d)"

    (
        export HOME="$test_dir"
        export CLAUDE_HOME="$HOME/.claude"
        mkdir -p "$CLAUDE_HOME/notifications" "$HOME/.codex"

        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/help.sh"
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/commands/global.sh"

        is_tool_installed() {
            [[ "$1" == "codex" ]] && return 0
            return 1
        }
        is_tool_enabled() {
            [[ "$1" == "codex" ]] && return 0
            return 1
        }
        is_tool_disable_needed() { return 1; }
        is_voice_enabled() { return 1; }
        is_sound_enabled() { return 1; }
        get_notify_types() { echo "idle_prompt"; }
        detect_os() { echo "linux"; }
        is_notify_type_enabled() {
            [[ "$1" == "idle_prompt" ]] && return 0
            return 1
        }

        local status_output alerts_output help_output
        status_output="$(show_status 2>&1)"
        alerts_output="$(show_alerts_status 2>&1)"
        help_output="$(show_help 2>&1)"

        [[ "$status_output" == *"Idle reminder: tmux-only post-completion watch when idle_prompt is enabled"* ]] \
            || fail "status output did not describe Codex idle reminders correctly"
        [[ "$alerts_output" == *"tmux-only idle reminder for Codex/Antigravity"* ]] \
            || fail "alerts status did not describe idle_prompt correctly"
        [[ "$alerts_output" == *"idle_prompt only gates the tmux-derived post-completion reminder"* ]] \
            || fail "alerts guidance still claimed idle_prompt does not apply to Codex"
        [[ "$help_output" == *"Codex has no native"* ]] \
            || fail "help output did not explain the Codex idle_prompt limitation"
    )

    rm -rf "$test_dir"
}

run_enable_all_alias_test
pass "cn on all enables all detected tools"

run_disable_all_alias_test
pass "cn off all disables all tools"

run_status_all_alias_test
pass "cn status all behaves like the global status command"

run_codex_idle_messaging_test
pass "Codex idle_prompt messaging explains the tmux-only reminder path"
