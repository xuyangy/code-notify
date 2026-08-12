#!/bin/bash

# opencode integration: plugin install/removal, notifier path rendering, and
# the notifier's opencode entry points.
#
# What this pins down:
#   - the plugin is RENDERED, not copied: an installed file still carrying the
#     @@CODE_NOTIFY_NOTIFIER@@ placeholder is a bridge that can never notify;
#   - "enabled" means "matches what `cn on opencode` would write now", so an
#     upgrade that moves the notifier or changes the plugin reads as REPAIR
#     NEEDED instead of silently running a stale bridge;
#   - the module has exactly one export. opencode's loader treats every export
#     as a plugin factory and rejects the whole file if one is not a function,
#     so an added `export const` would disable notifications entirely;
#   - the notifier's opencode suppression exempts code-notify's own plugin.
#     The plugin runs inside opencode, so OPENCODE=1 is set for its notifier
#     runs too, and a guard that ignored that would silence every one of them.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
LIB_DIR="$ROOT_DIR/lib/code-notify"
NOTIFIER="$LIB_DIR/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Plugin source: exactly one export, and it is a function.
# ---------------------------------------------------------------------------
source_file="$LIB_DIR/hooks/opencode/code-notify.ts"
[[ -f "$source_file" ]] || fail "opencode plugin source is missing"

export_count=$(grep -c '^export ' "$source_file" || true)
[[ "$export_count" -eq 1 ]] ||
    fail "plugin has $export_count exports; opencode rejects a module whose exports are not all plugin factories"
grep -q '^export const CodeNotify = async' "$source_file" ||
    fail "the single export is not the plugin factory"

# ---------------------------------------------------------------------------
# Install, enabled-detection and removal, under a path containing spaces.
# ---------------------------------------------------------------------------
run_install_test() {
    local base root install
    base="$test_dir/install"
    root="$base/dir with spaces"
    install="$base/code notify install"
    mkdir -p "$root" "$install"
    /bin/cp -R "$ROOT_DIR/lib" "$install/lib"

    (
        export HOME="$root"
        export CODE_NOTIFY_OPENCODE_CONFIG_DIR="$root/.config/opencode"

        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/colors.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/detect.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/core/config.sh"

        local plugin="$root/.config/opencode/plugin/code-notify.ts"

        is_tool_enabled opencode && fail "opencode reads as enabled before install"

        enable_tool opencode || fail "enable_tool opencode failed"
        [[ -f "$plugin" ]] || fail "plugin was not installed at $plugin"

        # The rendered path is what the whole integration hangs on.
        grep -q '@@CODE_NOTIFY_NOTIFIER@@' "$plugin" &&
            fail "installed plugin still carries the unrendered placeholder"
        grep -q "const NOTIFIER = \"$install/lib/code-notify/core/notifier.sh\"" "$plugin" ||
            fail "installed plugin does not point at this install's notifier"

        is_tool_enabled opencode || fail "is_tool_enabled opencode is false after install"

        # A plugin from another install (different notifier path) must read as
        # needing repair, not as enabled.
        local stale
        stale="$(sed 's|const NOTIFIER = .*|const NOTIFIER = "/somewhere/else/notifier.sh"|' "$plugin")"
        printf '%s\n' "$stale" > "$plugin"
        is_tool_enabled opencode && fail "a plugin pointing at another notifier reads as enabled"
        is_opencode_plugin_present || fail "a stale plugin is not reported as present"
        is_tool_disable_needed opencode || fail "cn off would skip a stale plugin"

        disable_tool opencode || fail "disable_tool opencode failed"
        [[ ! -e "$plugin" ]] || fail "cn off left the plugin behind"

        # The truncation a packed "<source> <target>" line would cause.
        [[ ! -e "${root%% *}" ]] || fail "a truncated path was used: ${root%% *} exists"
    )
}

run_install_test
pass "plugin installs rendered, detects staleness, and removes cleanly"

# ---------------------------------------------------------------------------
# The rendered notifier path survives characters that are legal in a path but
# meaningful to a substitution engine.
#
# Every one of these fails SILENTLY if rendering is wrong: the corrupt file
# still matches cmp (both sides equally corrupt) and still looks rendered, so
# `cn status` reports ENABLED while every notification, approvals included,
# goes to a path that does not exist. `&` is the matched text to sed, to awk's
# gsub, and to bash 5.2's ${x//y/z}; `\` is an escape to awk -v and to bash
# 5.2; `"` closes the TypeScript string literal the path sits in and stops the
# plugin loading at all. The spaced-path test above catches none of them.
# ---------------------------------------------------------------------------
run_hostile_path_test() {
    local base root install label
    for label in 'amp & dir' 'back\slash' 'quote"dir'; do
        base="$(mktemp -d "$test_dir/hostile.XXXXXX")"
        root="$base/home"
        install="$base/$label"
        mkdir -p "$root" "$install"
        /bin/cp -R "$ROOT_DIR/lib" "$install/lib"

        (
            export HOME="$root"
            export CODE_NOTIFY_OPENCODE_CONFIG_DIR="$root/.config/opencode"

            # shellcheck source=/dev/null
            source "$install/lib/code-notify/utils/colors.sh"
            # shellcheck source=/dev/null
            source "$install/lib/code-notify/utils/detect.sh"
            # shellcheck source=/dev/null
            source "$install/lib/code-notify/core/config.sh"

            local plugin="$root/.config/opencode/plugin/code-notify.ts"
            local expected="$install/lib/code-notify/core/notifier.sh"

            enable_tool opencode || fail "enable_tool opencode failed for [$label]"

            # The notifier the plugin will actually run has to be the real
            # file on disk. Reading it back through TypeScript's own string
            # rules is what proves the escaping and the substitution agree —
            # see the round-trip assertion in test-opencode-events.sh.
            grep -q '@@CODE_NOTIFY_NOTIFIER@@' "$plugin" &&
                fail "[$label] left the placeholder in the rendered plugin"
            [[ -f "$expected" ]] || fail "[$label] test set-up is wrong: no notifier at $expected"

            is_tool_enabled opencode || fail "[$label] did not read as enabled after install"
        )

        rm -rf "$base"
    done
}

run_hostile_path_test
pass "rendering survives &, backslash and quote in the install path"

# ---------------------------------------------------------------------------
# Notifier: opencode's own runs are exempt from the OPENCODE suppression.
# ---------------------------------------------------------------------------
fake_bin="$test_dir/bin"
tmux_log="$test_dir/tmux-calls.log"
mkdir -p "$fake_bin"
cat > "$fake_bin/tmux" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_TMUX_LOG"
exit 0
EOF
chmod +x "$fake_bin/tmux"

run_notifier() {
    # Each run gets a clean log; the caller inspects "$tmux_log".
    : > "$tmux_log"
    (
        export PATH="$fake_bin:$PATH"
        export FAKE_TMUX_LOG="$tmux_log"
        export HOME="$test_dir/home"
        mkdir -p "$HOME"
        export TMUX="$test_dir/fake-sock,1234,0"
        export TMUX_PANE="%1"
        export OPENCODE=1
        export OPENCODE_PID=4321
        bash "$NOTIFIER" "$@" < /dev/null > /dev/null 2>&1 || true
    )
}

# A replayed Claude hook inside opencode stays suppressed.
run_notifier UserPromptSubmit claude
[[ ! -s "$tmux_log" ]] ||
    fail "a replayed Claude hook inside opencode reached tmux: $(cat "$tmux_log")"
pass "replayed Claude hooks inside opencode stay suppressed"

# Naming the tool in argv is NOT an exemption: anything replaying hooks inside
# opencode could pass it, which is what this guard exists to stop.
run_notifier UserPromptSubmit opencode
[[ ! -s "$tmux_log" ]] ||
    fail "argv alone exempted a run from the OPENCODE guard: $(cat "$tmux_log")"
pass "the tool name in argv does not exempt a run"

# The env marker is the sole exemption. The plugin sets it on every notifier it
# spawns, so the detached runs the tmux watches fork from those processes carry
# it too — hence the empty tool name here, which such a run may well have.
run_marked_notifier() {
    : > "$tmux_log"
    (
        export PATH="$fake_bin:$PATH"
        export FAKE_TMUX_LOG="$tmux_log"
        export HOME="$test_dir/home"
        mkdir -p "$HOME"
        export TMUX="$test_dir/fake-sock,1234,0"
        export TMUX_PANE="%1"
        export OPENCODE=1
        export OPENCODE_PID=4321
        export CODE_NOTIFY_OPENCODE_HOOK=1
        bash "$NOTIFIER" "$@" < /dev/null > /dev/null 2>&1 || true
    )
}

run_marked_notifier UserPromptSubmit opencode
[[ -s "$tmux_log" ]] ||
    fail "the opencode plugin's own notifier run was suppressed by the OPENCODE guard"
pass "the opencode plugin's own runs are exempt via CODE_NOTIFY_OPENCODE_HOOK"

run_marked_notifier UserPromptSubmit ""
[[ -s "$tmux_log" ]] ||
    fail "CODE_NOTIFY_OPENCODE_HOOK did not exempt a forked run with no tool name"
pass "forked runs are exempt whatever argv they carry"

# ---------------------------------------------------------------------------
# SessionEnd tears the running indicator down without notifying.
# ---------------------------------------------------------------------------
notify_log="$test_dir/notify-calls.log"
cat > "$fake_bin/terminal-notifier" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_NOTIFY_LOG"
exit 0
EOF
chmod +x "$fake_bin/terminal-notifier"

: > "$tmux_log"
: > "$notify_log"
(
    export PATH="$fake_bin:$PATH"
    export FAKE_TMUX_LOG="$tmux_log"
    export FAKE_NOTIFY_LOG="$notify_log"
    export HOME="$test_dir/home"
    export TMUX="$test_dir/fake-sock,1234,0"
    export TMUX_PANE="%1"
    export OPENCODE=1
    export CODE_NOTIFY_OPENCODE_HOOK=1
    bash "$NOTIFIER" SessionEnd opencode < /dev/null > /dev/null 2>&1 || true
)
[[ ! -s "$notify_log" ]] ||
    fail "SessionEnd delivered a notification: $(cat "$notify_log")"
# Silence alone would also be the result of the event being ignored outright,
# which would leave the running indicator spinning — the failure this path
# exists to prevent. Reaching tmux is what makes it a teardown.
[[ -s "$tmux_log" ]] ||
    fail "SessionEnd never reached tmux, so nothing was torn down"
pass "SessionEnd is a silent teardown"

# ---------------------------------------------------------------------------
# Alert types gate opencode's approval and question prompts at RUNTIME.
#
# The plugin is one file reporting every event, so unlike Claude and Codex —
# whose permission hooks are only registered while the alert type is on —
# there is nothing to gate at install time. If this gate were missing,
# `cn alerts remove permission_prompt` would silently do nothing for opencode.
# ---------------------------------------------------------------------------
run_permission_notification() {
    : > "$notify_log"
    (
        export PATH="$fake_bin:$PATH"
        export FAKE_TMUX_LOG="$tmux_log"
        export FAKE_NOTIFY_LOG="$notify_log"
        export HOME="$test_dir/home"
        export OPENCODE=1
        export CODE_NOTIFY_OPENCODE_HOOK=1
        printf '%s' '{"type":"permission_prompt"}' |
            bash "$NOTIFIER" notification opencode cn-test > /dev/null 2>&1 || true
    )
}

mkdir -p "$test_dir/home/.claude/notifications"

printf 'idle_prompt' > "$test_dir/home/.claude/notifications/notify-types"
run_permission_notification
[[ ! -s "$notify_log" ]] ||
    fail "an approval prompt notified with permission_prompt alerts off: $(cat "$notify_log")"
pass "approval prompts respect permission_prompt being off"

printf 'idle_prompt|permission_prompt' > "$test_dir/home/.claude/notifications/notify-types"
run_permission_notification
[[ -s "$notify_log" ]] ||
    fail "an approval prompt did not notify with permission_prompt alerts on"
pass "approval prompts fire with permission_prompt on"

echo "All opencode integration tests passed"
