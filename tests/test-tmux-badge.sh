#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# Stateful fake tmux: window options persist as files under
# $FAKE_TMUX_STATE/<window>.<option> so set/show/unset round-trip across
# invocations, the way real tmux window options do across hook processes.
fake_bin="$test_dir/bin"
log_file="$test_dir/tmux-calls.log"
state_dir="$test_dir/state"
mkdir -p "$fake_bin" "$state_dir"
cat > "$fake_bin/tmux" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_TMUX_LOG"
args=("$@")
if [[ "${args[0]}" == "-S" ]]; then
    args=("${args[@]:2}")
fi
cmd="${args[0]}"
args=("${args[@]:1}")
target=""
unset_opt=0
rest=()
while (( ${#args[@]} )); do
    a="${args[0]}"
    case "$a" in
        -t) target="${args[1]}"; args=("${args[@]:2}") ;;
        -F) args=("${args[@]:2}") ;;
        -*) [[ "$a" == -*u* ]] && unset_opt=1; args=("${args[@]:1}") ;;
        *) rest+=("$a"); args=("${args[@]:1}") ;;
    esac
done
case "$cmd" in
    display-message)
        # The badge info format is pipe-separated; a plain window-name query
        # reads the stateful name (kept current by rename-window); the focus
        # target format (session/window/pane IDs) is a fixture.
        case "${rest[0]}" in
            *"|"*) printf '%s\n' "$FAKE_TMUX_BADGE_INFO" ;;
            '#{window_name}') cat "$FAKE_TMUX_STATE/${target}.window_name" 2>/dev/null; echo ;;
            *) printf '%s\n' "$FAKE_TMUX_TARGET" ;;
        esac
        ;;
    list-windows)
        printf '%s\n' "$FAKE_TMUX_WINDOWS"
        ;;
    show-options)
        cat "$FAKE_TMUX_STATE/${target}.${rest[0]}" 2>/dev/null
        ;;
    set-option)
        if (( unset_opt )); then
            rm -f "$FAKE_TMUX_STATE/${target}.${rest[0]}"
        else
            printf '%s' "${rest[1]}" > "$FAKE_TMUX_STATE/${target}.${rest[0]}"
        fi
        ;;
    rename-window)
        printf '%s' "${rest[0]}" > "$FAKE_TMUX_STATE/${target}.window_name"
        ;;
esac
exit 0
EOF
chmod +x "$fake_bin/tmux"
export PATH="$fake_bin:$PATH"
export FAKE_TMUX_LOG="$log_file"
export FAKE_TMUX_STATE="$state_dir"

# Keep the disabled-flag file inside the sandbox
export HOME="$test_dir/home"
mkdir -p "$HOME"

source "$ROOT_DIR/lib/code-notify/utils/tmux.sh"

export TMUX="$test_dir/sock,12345,0"
export TMUX_PANE="%3"
# shellcheck disable=SC2016  # $1 is a literal tmux session ID, not a parameter
export FAKE_TMUX_TARGET='$1 @2 %3'
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
export FAKE_TMUX_WINDOWS=""

window_name() { cat "$state_dir/@2.window_name" 2>/dev/null; }
orig_option() { cat "$state_dir/@2.@code_notify_orig_name" 2>/dev/null; }

# --- disabled via environment ---
CODE_NOTIFY_TMUX_BADGE=false tmux_badge_set "🎯" && fail "badge should be skipped when disabled via env"
[[ -z "$(window_name)" ]] || fail "disabled badge should not rename the window"
pass "disabled via environment"

# --- disabled via flag file ---
mkdir -p "$HOME/.claude/notifications"
touch "$HOME/.claude/notifications/tmux-badge-disabled"
tmux_badge_set "🎯" && fail "badge should be skipped when disabled via flag file"
rm -f "$HOME/.claude/notifications/tmux-badge-disabled"
pass "disabled via flag file"

# --- no-op outside tmux ---
(
    unset TMUX TMUX_PANE
    tmux_badge_set "🎯" && exit 1
    exit 0
) || fail "badge should fail outside tmux"
pass "no-op outside tmux"

# --- badge happy path ---
tmux_badge_set "🎯" || fail "badge should succeed inside tmux"
[[ "$(window_name)" == "🎯 zsh" ]] || fail "window should be renamed with icon prefix (got: $(window_name))"
[[ "$(orig_option)" == "zsh" ]] || fail "original name should be saved in window option"
[[ "$(cat "$state_dir/@2.@code_notify_autorename")" == "on" ]] || fail "automatic-rename state should be saved"
pass "badge sets icon and saves state"

# --- repeat badge swaps icon, no stacking ---
tmux_badge_set "👋" || fail "second badge should succeed"
[[ "$(window_name)" == "👋 zsh" ]] || fail "second badge should swap the icon, not stack (got: $(window_name))"
[[ "$(orig_option)" == "zsh" ]] || fail "original name must survive a repeat badge"
pass "repeat badge swaps icon"

# --- clear restores name, automatic-rename, and removes options ---
: > "$log_file"
tmux_badge_clear "@2"
[[ "$(window_name)" == "zsh" ]] || fail "clear should restore the original name"
grep -q -- "set-option -w -t @2 automatic-rename on" "$log_file" || fail "clear should restore automatic-rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear should unset the orig-name option"
[[ ! -f "$state_dir/@2.@code_notify_autorename" ]] || fail "clear should unset the autorename option"
[[ ! -f "$state_dir/@2.@code_notify_badged_name" ]] || fail "clear should unset the badged-name option"
pass "clear restores window state"

# --- clear is a no-op without a badge ---
: > "$log_file"
tmux_badge_clear "@2"
grep -q "rename-window" "$log_file" && fail "clear without badge should not rename"
pass "clear no-op without badge"

# --- manual rename while badged becomes the new original ---
tmux_badge_set "🎯" || fail "badge before manual rename should succeed"
export FAKE_TMUX_BADGE_INFO='@2|off|0|work'   # user renamed the badged window
tmux_badge_set "👋" || fail "badge after manual rename should succeed"
[[ "$(window_name)" == "👋 work" ]] || fail "badge should adopt the user's new name (got: $(window_name))"
[[ "$(orig_option)" == "work" ]] || fail "manual rename should replace the saved original"
[[ "$(cat "$state_dir/@2.@code_notify_autorename")" == "off" ]] || fail "manual rename should pin automatic-rename off"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
pass "manual rename becomes the new original"

# --- a rename that merely ends in the original name is still manual ---
# "api zsh" ends in " zsh", so a suffix match alone would mistake it for a
# badged form of "zsh"; the exact badged-name comparison must not.
tmux_badge_clear "@2"                          # reset state from the previous case
tmux_badge_set "🎯" || fail "badge before suffix-colliding rename should succeed"
export FAKE_TMUX_BADGE_INFO='@2|off|0|api zsh'   # user renamed "🎯 zsh" -> "api zsh"
tmux_badge_set "👋" || fail "badge after suffix-colliding rename should succeed"
[[ "$(window_name)" == "👋 api zsh" ]] || fail "badge should adopt a rename ending in the original name (got: $(window_name))"
[[ "$(orig_option)" == "api zsh" ]] || fail "suffix-colliding rename should replace the saved original"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
pass "suffix-colliding rename becomes the new original"

# --- clear keeps a manual rename ---
tmux_badge_clear "@2"                          # reset state from the previous case
tmux_badge_set "🎯" || fail "badge for manual-rename clear test should succeed"
printf '%s' "work" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
tmux_badge_clear "@2"
[[ "$(window_name)" == "work" ]] || fail "clear must not clobber a manual rename (got: $(window_name))"
grep -q "automatic-rename on" "$log_file" && fail "clear after a manual rename must not re-enable automatic-rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear should still drop the badge state"
pass "clear keeps manual rename"

# --- clear keeps a manual rename that ends in the original name ---
tmux_badge_set "🎯" || fail "badge for suffix-colliding clear test should succeed"
printf '%s' "api zsh" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
tmux_badge_clear "@2"
[[ "$(window_name)" == "api zsh" ]] || fail "clear must not clobber a rename ending in the original name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear should still drop the badge state after a suffix-colliding rename"
pass "clear keeps suffix-colliding manual rename"

# --- legacy badge (no badged-name option) still clears via suffix match ---
printf '%s' "zsh" > "$state_dir/@2.@code_notify_orig_name"
printf '%s' "on" > "$state_dir/@2.@code_notify_autorename"
printf '%s' "🎯 zsh" > "$state_dir/@2.window_name"
rm -f "$state_dir/@2.@code_notify_badged_name"
tmux_badge_clear "@2"
[[ "$(window_name)" == "zsh" ]] || fail "legacy badge without a saved badged name should still restore (got: $(window_name))"
pass "legacy badge clears without badged-name option"

# --- visible window is not badged ---
export FAKE_TMUX_BADGE_INFO='@2|on|1|zsh'
: > "$log_file"
tmux_badge_set "🎯" || fail "badge on visible window should still exit 0"
grep -q "rename-window" "$log_file" && fail "visible window should not be renamed"
pass "visible window skipped"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'

# --- malformed window id is rejected ---
export FAKE_TMUX_BADGE_INFO='@2; rm -rf /|on|0|zsh'
tmux_badge_set "🎯" && fail "badge should reject a non-ID window"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
pass "unsafe window id rejection"

# --- sweep clears only badged windows that are visible again ---
tmux_badge_set "🎯" || fail "badge for sweep setup should succeed"
printf '%s' "other" > "$state_dir/@5.@code_notify_orig_name"
export FAKE_TMUX_WINDOWS=$'@2|1|zsh\n@5|0|other\n@7|1|'
tmux_badge_sweep
[[ "$(window_name)" == "zsh" ]] || fail "sweep should restore the visited window"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "sweep should unset options on the visited window"
[[ -f "$state_dir/@5.@code_notify_orig_name" ]] || fail "sweep must not touch a badged window that is still hidden"
pass "sweep clears visited windows only"

# --- clear command structure ---
cmd=$(tmux_badge_build_clear_command) || fail "clear command should build inside tmux"
[[ "$cmd" == *"-S '$test_dir/sock'"* ]] || fail "clear command should target the captured socket"
[[ "$cmd" == *"rename-window -t '@2'"* ]] || fail "clear command should rename the origin window"
[[ "$cmd" == *"@code_notify_orig_name"* ]] || fail "clear command should read the saved name"
[[ "$cmd" == *"@code_notify_badged_name"* ]] || fail "clear command should read the saved badged name"
[[ "$cmd" == *'#{window_name}'* ]] || fail "clear command should check the live window name"
pass "clear command structure"

# --- generated clear command restores a badged window ---
tmux_badge_set "🧨" || fail "badge for clear-command test should succeed"
[[ "$(window_name)" == "🧨 zsh" ]] || fail "precondition: window should be badged"
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "generated clear command should run cleanly"
[[ "$(window_name)" == "zsh" ]] || fail "generated command should restore the original name"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "generated command should unset the saved options"
pass "generated clear command execution"

# --- generated clear command is a no-op without a badge ---
: > "$log_file"
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "clear command should run cleanly without a badge"
grep -q "rename-window" "$log_file" && fail "clear command without badge should not rename"
pass "generated clear command no-op"

# --- generated clear command keeps a manual rename ---
tmux_badge_set "🎯" || fail "badge for manual-rename clear-command test should succeed"
printf '%s' "work" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "clear command should run cleanly after a manual rename"
[[ "$(window_name)" == "work" ]] || fail "clear command must not clobber a manual rename (got: $(window_name))"
grep -q "rename-window" "$log_file" && fail "clear command after a manual rename should not rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear command should still drop the badge state"
pass "generated clear command keeps manual rename"

# --- generated clear command keeps a rename that ends in the original name ---
tmux_badge_set "🎯" || fail "badge for suffix-colliding clear-command test should succeed"
printf '%s' "api zsh" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "clear command should run cleanly after a suffix-colliding rename"
[[ "$(window_name)" == "api zsh" ]] || fail "clear command must not clobber a rename ending in the original name (got: $(window_name))"
grep -q "rename-window" "$log_file" && fail "clear command after a suffix-colliding rename should not rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear command should still drop the badge state after a suffix-colliding rename"
pass "generated clear command keeps suffix-colliding manual rename"

# --- notifier.sh end-to-end wiring (macOS only) ---
# A stop event should badge the origin window with 🎯 and hand the badge
# clear command to terminal-notifier via -execute alongside -focus.
if [[ "$(uname -s)" == "Darwin" ]]; then
    NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"
    tn_log="$test_dir/terminal-notifier.log"

    cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then echo "-focus"; exit 0; fi
printf '%s\n' "\$@" >> "$tn_log"
EOF
    chmod +x "$fake_bin/terminal-notifier"

    rm -f "$state_dir"/*
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh should exit cleanly"

    [[ "$(window_name)" == "🎯 zsh" ]] || fail "notifier should badge the origin window with the stop icon (got: $(window_name))"
    grep -qx -- "-focus" "$tn_log" || fail "notifier should pass -focus"
    grep -qx -- "-execute" "$tn_log" || fail "notifier should pass -execute"
    grep -q -- "@code_notify_orig_name" "$tn_log" || fail "notifier -execute should carry the badge clear command"
    pass "notifier end-to-end badge wiring"
fi

echo "All tmux badge tests passed"
