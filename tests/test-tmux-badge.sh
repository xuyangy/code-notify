#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Resolve the real tmux binary now, before the fake tmux is put on PATH below.
# The real-tmux quoting test and the cleanup trap must use this absolute path;
# a bare `tmux` would hit the fake and neither detect the version nor actually
# kill the throwaway server.
REAL_TMUX="$(command -v tmux 2>/dev/null || true)"

test_dir="$(mktemp -d)"
# Dedicated throwaway tmux socket for the real-tmux quoting test below, on its
# own -L socket so it never touches the user's tmux. On every exit path (pass,
# fail's `exit 1`, or error) the server is killed AND the socket file it leaves
# behind is removed — kill-server does not unlink the socket, so we capture the
# real path from tmux (#{socket_path}) into quote_sock_path and rm it here.
QUOTE_SOCK="cn-badge-qtest-$$"
quote_sock_path=""
cleanup() {
    if [[ -n "$REAL_TMUX" ]]; then
        # || true: on skip/early-exit paths no server was started, so kill-server
        # fails on a nonexistent socket; under set -e that would abort the trap
        # before rm and taint the script's exit status.
        "$REAL_TMUX" -L "$QUOTE_SOCK" kill-server 2>/dev/null || true
        [[ -n "$quote_sock_path" ]] && rm -f "$quote_sock_path"
    fi
    rm -rf "$test_dir"
}
trap cleanup EXIT

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
fmt=""
unset_opt=0
rest=()
while (( ${#args[@]} )); do
    a="${args[0]}"
    case "$a" in
        -t) target="${args[1]}"; args=("${args[@]:2}") ;;
        -F) fmt="${args[1]}"; args=("${args[@]:2}") ;;
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
            '#{window_id}') printf '%s\n' "${FAKE_TMUX_PANE_WINDOW-@2}" ;;
            *) printf '%s\n' "$FAKE_TMUX_TARGET" ;;
        esac
        ;;
    list-windows)
        # The badge sweep and the running sweep ask for different formats; the
        # badge one (containing window_active) comes from the fixture var, the
        # running ones are synthesized from the stateful @code_notify_running
        # options so epoch round-trips are exercised for real.
        if [[ "$fmt" == *window_active* ]]; then
            printf '%s\n' "$FAKE_TMUX_WINDOWS"
        elif [[ "$fmt" == *resume_pending* ]]; then
            # The resume poll pairs each pending epoch with the window's
            # activity clock and dialog snapshot; the activity value comes
            # from a per-window state file so tests can move it independently
            # of the pause epoch.
            for f in "$FAKE_TMUX_STATE"/@*.@code_notify_resume_pending; do
                [[ -e "$f" ]] || continue
                w="${f##*/}"; w="${w%%.*}"
                act=$(cat "$FAKE_TMUX_STATE/${w}.window_activity" 2>/dev/null)
                fp=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_pause_fp" 2>/dev/null)
                printf '%s|%s|%s|%s\n' "$w" "$(cat "$f")" "$act" "$fp"
            done
        elif [[ "$fmt" == *code_notify_agent_pid* ]]; then
            # Real tmux emits EVERY window, with an empty field when the
            # option is unset — the sweep must cope with untracked windows,
            # so list every window any state file mentions, not just tracked.
            seen=" "
            for f in "$FAKE_TMUX_STATE"/@*.*; do
                [[ -e "$f" ]] || continue
                w="${f##*/}"; w="${w%%.*}"
                case "$seen" in *" $w "*) continue ;; esac
                seen="$seen$w "
                pid=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_agent_pid" 2>/dev/null)
                run=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_running" 2>/dev/null)
                sp=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_settle_pane" 2>/dev/null)
                iw=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_idle_watch" 2>/dev/null)
                printf '%s|%s|%s|%s|%s\n' "$w" "$pid" "$run" "$sp" "$iw"
            done
        else
            for f in "$FAKE_TMUX_STATE"/*.@code_notify_running; do
                [[ -e "$f" ]] || continue
                w="${f##*/}"; w="${w%%.*}"
                since=$(cat "$f")
                if [[ "$fmt" == *clear_mode* ]]; then
                    mode=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_clear_mode" 2>/dev/null)
                    printf '%s|%s|%s\n' "$w" "$since" "$mode"
                else
                    printf '%s|%s\n' "$w" "$since"
                fi
            done
        fi
        ;;
    list-sessions)
        printf '%s\n' "$FAKE_TMUX_SESSIONS"
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
    capture-pane)
        # Real capture-pane fails on a vanished pane; mirror that so the
        # fail-propagation in tmux_resume_poll_fingerprint is exercised.
        cat "$FAKE_TMUX_STATE/${target}.pane_content" 2>/dev/null || exit 1
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

# A hook launcher commonly has `codex` in its `sh -c` command line. The exit
# tracker must skip that short-lived wrapper and retain the actual agent parent.
resolved_agent_pid=$( (
    ps() {
        # ppid+comm and command are queried separately; answer each shape.
        if [[ "$*" == *command=* ]]; then
            case "${*: -1}" in
                100) printf '%s\n' '/bin/sh -c notifier.sh stop codex' ;;
                200) printf '%s\n' '/usr/local/bin/codex --resume' ;;
            esac
        else
            case "${*: -1}" in
                100) printf '%s\n' '  200 /bin/sh' ;;
                200) printf '%s\n' '    1 /usr/local/bin/codex' ;;
            esac
        fi
    }
    tmux_agent_exit_resolve_pid codex 100
) )
[[ "$resolved_agent_pid" == "200" ]] \
    || fail "agent exit tracker should skip a shell wrapper (got: $resolved_agent_pid)"
pass "agent exit tracker resolves the real agent process"

export TMUX="$test_dir/sock,12345,0"
export TMUX_PANE="%3"
# shellcheck disable=SC2016  # $1 is a literal tmux session ID, not a parameter
export FAKE_TMUX_TARGET='$1 @2 %3'
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
export FAKE_TMUX_WINDOWS=""
export FAKE_TMUX_SESSIONS=""

window_name() { cat "$state_dir/@2.window_name" 2>/dev/null; }
orig_option() { cat "$state_dir/@2.@code_notify_orig_name" 2>/dev/null; }

# --- disabled via environment ---
CODE_NOTIFY_TMUX_BADGE=false tmux_badge_set "🟢" && fail "badge should be skipped when disabled via env"
[[ -z "$(window_name)" ]] || fail "disabled badge should not rename the window"
pass "disabled via environment"

# --- disabled via flag file ---
mkdir -p "$HOME/.claude/notifications"
touch "$HOME/.claude/notifications/tmux-badge-disabled"
tmux_badge_set "🟢" && fail "badge should be skipped when disabled via flag file"
rm -f "$HOME/.claude/notifications/tmux-badge-disabled"
pass "disabled via flag file"

# --- no-op outside tmux ---
(
    unset TMUX TMUX_PANE
    tmux_badge_set "🟢" && exit 1
    exit 0
) || fail "badge should fail outside tmux"
pass "no-op outside tmux"

# --- badge happy path ---
tmux_badge_set "🟢" || fail "badge should succeed inside tmux"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "window should be renamed with icon prefix (got: $(window_name))"
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
tmux_badge_set "🟢" || fail "badge before manual rename should succeed"
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
tmux_badge_set "🟢" || fail "badge before suffix-colliding rename should succeed"
export FAKE_TMUX_BADGE_INFO='@2|off|0|api zsh'   # user renamed "🟢 zsh" -> "api zsh"
tmux_badge_set "👋" || fail "badge after suffix-colliding rename should succeed"
[[ "$(window_name)" == "👋 api zsh" ]] || fail "badge should adopt a rename ending in the original name (got: $(window_name))"
[[ "$(orig_option)" == "api zsh" ]] || fail "suffix-colliding rename should replace the saved original"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
pass "suffix-colliding rename becomes the new original"

# --- clear keeps a manual rename ---
tmux_badge_clear "@2"                          # reset state from the previous case
tmux_badge_set "🟢" || fail "badge for manual-rename clear test should succeed"
printf '%s' "work" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
tmux_badge_clear "@2"
[[ "$(window_name)" == "work" ]] || fail "clear must not clobber a manual rename (got: $(window_name))"
grep -q "automatic-rename on" "$log_file" && fail "clear after a manual rename must not re-enable automatic-rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear should still drop the badge state"
pass "clear keeps manual rename"

# --- clear keeps a manual rename that ends in the original name ---
tmux_badge_set "🟢" || fail "badge for suffix-colliding clear test should succeed"
printf '%s' "api zsh" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
tmux_badge_clear "@2"
[[ "$(window_name)" == "api zsh" ]] || fail "clear must not clobber a rename ending in the original name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear should still drop the badge state after a suffix-colliding rename"
pass "clear keeps suffix-colliding manual rename"

# --- legacy badge (no badged-name option) still clears via suffix match ---
printf '%s' "zsh" > "$state_dir/@2.@code_notify_orig_name"
printf '%s' "on" > "$state_dir/@2.@code_notify_autorename"
printf '%s' "🟢 zsh" > "$state_dir/@2.window_name"
rm -f "$state_dir/@2.@code_notify_badged_name"
tmux_badge_clear "@2"
[[ "$(window_name)" == "zsh" ]] || fail "legacy badge without a saved badged name should still restore (got: $(window_name))"
pass "legacy badge clears without badged-name option"

# --- visible window is not badged ---
export FAKE_TMUX_BADGE_INFO='@2|on|1|zsh'
: > "$log_file"
tmux_badge_set "🟢" || fail "badge on visible window should still exit 0"
grep -q "rename-window" "$log_file" && fail "visible window should not be renamed"
pass "visible window skipped"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'

# --- a terminal event badges even the visible window, replacing a stale
# waiting badge (e.g. a permission prompt answered inline, then the task
# finishes while the user is looking right at the window) ---
tmux_badge_set "👋" engage || fail "stale-badge setup should succeed"
[[ "$(window_name)" == "👋 zsh" ]] || fail "precondition: window should carry the stale badge"
export FAKE_TMUX_BADGE_INFO='@2|on|1|👋 zsh'   # user is now looking at the window
tmux_badge_set "🟢" engage "" apply || fail "terminal badge on visible window should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "terminal event should badge the visible window (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
    || fail "the visible completion badge should keep engage clear mode"
pass "terminal event badges the visible window, replacing a stale one"
tmux_badge_clear "@2"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'

# --- a completion on a bare focused window still gets its badge ---
export FAKE_TMUX_BADGE_INFO='@2|on|1|zsh'
tmux_badge_set "🟢" engage "" apply || fail "completion badge on a bare visible window should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "completion badge should always show (got: $(window_name))"
pass "completion badge lands on a bare visible window"
tmux_badge_clear "@2"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'

# --- a waiting-type event (idle reminder, permission, mid-run) still skips
# the visible window and keeps an existing badge: it must not wipe or restack
# a done/complete badge the user has not engaged away yet ---
tmux_badge_set "🟢" engage || fail "done-badge setup should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "precondition: window should carry the done badge"
export FAKE_TMUX_BADGE_INFO='@2|on|1|🟢 zsh'   # user reads the output; idle reminder fires
tmux_badge_set "👋" engage || fail "waiting badge attempt on visible window should still exit 0"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "waiting event must keep the done badge (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
    || fail "waiting event must keep the badge state"
pass "waiting event keeps an existing badge on a visible window"
tmux_badge_clear "@2"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'

# --- badge-visible toggle: env var wins, flag file is the persistent state ---
# The notifier promotes every event to visible_action=apply when this is on.
tmux_badge_visible_enabled && fail "badge-visible should default to off"
CODE_NOTIFY_TMUX_BADGE_VISIBLE=true tmux_badge_visible_enabled \
    || fail "badge-visible env true should enable"
touch "$HOME/.claude/notifications/tmux-badge-visible-enabled"
tmux_badge_visible_enabled || fail "badge-visible flag file should enable"
CODE_NOTIFY_TMUX_BADGE_VISIBLE=false tmux_badge_visible_enabled \
    && fail "badge-visible env false should override the flag file"
rm -f "$HOME/.claude/notifications/tmux-badge-visible-enabled"
pass "badge-visible toggle honours env and flag file"

# --- malformed window id is rejected ---
export FAKE_TMUX_BADGE_INFO='@2; rm -rf /|on|0|zsh'
tmux_badge_set "🟢" && fail "badge should reject a non-ID window"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
pass "unsafe window id rejection"

# --- sweep clears only badged windows that are visible again ---
# list-windows format: window_id|visible|clear_mode|orig_name
tmux_badge_set "🟢" || fail "badge for sweep setup should succeed"
printf '%s' "other" > "$state_dir/@5.@code_notify_orig_name"
export FAKE_TMUX_WINDOWS=$'@2|1|glance|zsh\n@5|0|glance|other\n@7|1||'
tmux_badge_sweep
[[ "$(window_name)" == "zsh" ]] || fail "sweep should restore the visited window"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "sweep should unset options on the visited window"
[[ -f "$state_dir/@5.@code_notify_orig_name" ]] || fail "sweep must not touch a badged window that is still hidden"
pass "sweep clears visited windows only"
rm -f "$state_dir/@5.@code_notify_orig_name"
export FAKE_TMUX_WINDOWS=""

# --- badge-set arms the focus-clear server hook ---
: > "$log_file"
tmux_badge_set "🟢" || fail "badge for hook-install test should succeed"
grep -qF "set-hook -g session-window-changed[8471]" "$log_file" \
    || fail "badge-set should install the session-window-changed focus hook"
grep -qF "set-hook -g client-session-changed[8471]" "$log_file" \
    || fail "badge-set should install the client-session-changed focus hook"
grep -qF "set-hook -g client-attached[8471]" "$log_file" \
    || fail "badge-set should install the client-attached focus hook"
grep -q "badge-sweep" "$log_file" || fail "focus hook should invoke badge-sweep"
pass "badge-set arms the focus-clear hook"

# --- the hook entry point (`tmux.sh badge-sweep`) clears from a subprocess ---
# This is exactly what the tmux hook runs: a fresh `bash tmux.sh badge-sweep`,
# with no TMUX_PANE. It must still clear the now-visible badged window. The
# empty clear-mode field doubles as the legacy-badge case (written before
# @code_notify_clear_mode existed): no saved mode is treated as glance.
export FAKE_TMUX_WINDOWS=$'@2|1||zsh'
env -u TMUX_PANE bash "$ROOT_DIR/lib/code-notify/utils/tmux.sh" badge-sweep
[[ "$(window_name)" == "zsh" ]] \
    || fail "badge-sweep subcommand should clear the visited window (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] \
    || fail "badge-sweep subcommand should drop the badge state"
export FAKE_TMUX_WINDOWS=""
pass "badge-sweep subcommand clears without TMUX_PANE"

# --- sweep is a no-op with no tmux server (TMUX unset) ---
tmux_badge_set "🟢" || fail "badge for no-server sweep should succeed"
: > "$log_file"
( unset TMUX; tmux_badge_sweep )
grep -q "list-windows" "$log_file" && fail "sweep should not query tmux when TMUX is unset"
tmux_badge_clear "@2"
export FAKE_TMUX_WINDOWS=""
pass "sweep no-ops without a tmux server"

# --- sweep retires the focus hook once no badge remains ---
tmux_badge_set "🟢" || fail "badge for hook-retire test should succeed"
export FAKE_TMUX_WINDOWS=$'@2|1|glance|zsh'   # the only badged window, now visible
: > "$log_file"
tmux_badge_sweep
[[ "$(window_name)" == "zsh" ]] || fail "sweep should clear the last badge"
grep -qF "set-hook -gu session-window-changed[8471]" "$log_file" \
    || fail "sweep should retire the session hook when no badge remains"
grep -qF "set-hook -gu client-session-changed[8471]" "$log_file" \
    || fail "sweep should retire the client hook when no badge remains"
grep -qF "set-hook -gu client-attached[8471]" "$log_file" \
    || fail "sweep should retire the client-attached hook when no badge remains"
export FAKE_TMUX_WINDOWS=""
pass "sweep retires the focus hook when no badge remains"

# --- sweep keeps the hook while a badged window is still hidden ---
tmux_badge_set "🟢" || fail "badge for hook-keep test should succeed"
printf '%s' "other" > "$state_dir/@5.@code_notify_orig_name"
export FAKE_TMUX_WINDOWS=$'@2|1|glance|zsh\n@5|0|glance|other'   # @5 still hidden + badged
: > "$log_file"
tmux_badge_sweep
grep -qF "set-hook -gu session-window-changed[8471]" "$log_file" \
    && fail "sweep must not retire the hook while a badge is still pending"
rm -f "$state_dir/@5.@code_notify_orig_name"
export FAKE_TMUX_WINDOWS=""
pass "sweep keeps the focus hook while a badge is still pending"

# --- focus hook self-retires when the lib has been uninstalled ---
# The hook payload embeds an absolute lib path that can outlive the install.
# With the lib gone the guard must unset both hooks via the embedded tmux
# binary + socket (run-shell guarantees neither PATH nor $TMUX) instead of
# erroring on every window switch forever. Exercised exactly as tmux would:
# the payload is pulled out of the recorded set-hook call and run with /bin/sh.
lib_copy="$test_dir/lib-copy.sh"
cp "$ROOT_DIR/lib/code-notify/utils/tmux.sh" "$lib_copy"
saved_lib_path="$TMUX_BADGE_LIB_PATH"
TMUX_BADGE_LIB_PATH="$lib_copy"
: > "$log_file"
tmux_badge_set "🟢" || fail "badge for self-retire test should succeed"
grep -qF 'run-shell -b "if [ -f ' "$log_file" \
    || fail "hook payload should guard on the lib file existing"
payload=$(sed -n 's/^set-hook -g session-window-changed\[8471\] run-shell -b "\(.*\)"$/\1/p' "$log_file" | head -n 1)
[[ -n "$payload" ]] || fail "hook payload should be extractable from the set-hook call"

# lib still present: the payload's sweep branch clears the visible badge
export FAKE_TMUX_WINDOWS=$'@2|1|glance|zsh'
env -u TMUX_PANE /bin/sh -c "$payload" || fail "hook payload should run cleanly with the lib present"
[[ "$(window_name)" == "zsh" ]] \
    || fail "hook payload should sweep the badge while the lib exists (got: $(window_name))"
export FAKE_TMUX_WINDOWS=""

# lib gone: the payload unsets both hooks through the embedded tmux + socket
tmux_badge_set "🟢" || fail "re-badge for self-retire test should succeed"
rm -f "$lib_copy"
: > "$log_file"
env -u TMUX_PANE /bin/sh -c "$payload" || fail "hook payload should exit 0 with the lib missing"
grep -qF -- "-S $test_dir/sock set-hook -gu session-window-changed[8471]" "$log_file" \
    || fail "payload should self-retire the session hook when the lib is gone"
grep -qF -- "-S $test_dir/sock set-hook -gu client-session-changed[8471]" "$log_file" \
    || fail "payload should self-retire the client hook when the lib is gone"
grep -qF -- "-S $test_dir/sock set-hook -gu client-attached[8471]" "$log_file" \
    || fail "payload should self-retire the client-attached hook when the lib is gone"
grep -q "list-windows" "$log_file" && fail "payload must not attempt a sweep when the lib is gone"
tmux_badge_clear "@2"
TMUX_BADGE_LIB_PATH="$saved_lib_path"
pass "focus hook self-retires when the lib is gone"

# --- real tmux: the hook payload parses even with quote-hostile paths ---
# The fake tmux above logs calls and stores options but does NOT replicate
# tmux's own command-string parser, which re-processes \, " and $ inside "..."
# when a hook fires. So the tmux-quoting (tmux_focus_cmd_quote) is exercised
# here against a real, throwaway tmux server: a hook whose payload embeds a path
# containing " $ space and \ must still parse and run. Shell-quoting alone would
# let the " terminate tmux's double-quoted argument early and break the parse.
# The server uses a dedicated -L socket (killed by the EXIT trap) and -f
# /dev/null, so it never touches the user's tmux or config.
tmux_major=0
if [[ -n "$REAL_TMUX" ]]; then
    tmux_major=$("$REAL_TMUX" -V 2>/dev/null | grep -oE '[0-9]+' | head -n 1)
fi
if [[ "${tmux_major:-0}" -ge 3 ]]; then
    # dir name with " $ space \ and #{...} — all tmux-hostile. The #{q} exercises
    # run-shell's format expansion: an unescaped # would be rewritten as a format
    # before /bin/sh ever ran.
    qdir="$test_dir/pa\"th\$x #{q} \\y"
    marker="$qdir/fired.txt"
    mkdir -p "$qdir"
    # Build the payload exactly as tmux_badge_install_focus_hook does: an inner
    # shell command with shell-quoted paths, then the whole run-shell argument
    # tmux-quoted. run-shell (no -b) is synchronous so no polling race, but the
    # parse tmux performs is identical to the -b form the real hook uses.
    inner="touch $(tmux_focus_shell_quote "$marker")"
    payload="run-shell $(tmux_focus_cmd_quote "$inner")"
    "$REAL_TMUX" -L "$QUOTE_SOCK" -f /dev/null new-session -d -x 80 -y 24 \
        || fail "real-tmux: throwaway server should start"
    # Record the socket path so the EXIT trap can remove the file kill-server
    # leaves behind, wherever tmux placed it.
    quote_sock_path="$("$REAL_TMUX" -L "$QUOTE_SOCK" display-message -p '#{socket_path}' 2>/dev/null)"
    "$REAL_TMUX" -L "$QUOTE_SOCK" set-hook -g "session-window-changed[8471]" "$payload"
    "$REAL_TMUX" -L "$QUOTE_SOCK" new-window        # fires session-window-changed
    i=0
    while [[ ! -f "$marker" && "$i" -lt 20 ]]; do sleep 0.1; i=$((i + 1)); done
    [[ -f "$marker" ]] \
        || fail "real-tmux: hook payload with quote-hostile paths should parse and run"
    pass "real-tmux hook payload survives quote-hostile paths"
else
    pass "real-tmux quote test skipped (tmux >= 3.0 not available)"
fi

# --- tmux_badge_clear_current clears the caller's own window ---
# The engage-clear path: an agent's UserPromptSubmit hook runs this to drop the
# badge on the window the user just handed work, resolving the window from the
# current pane (FAKE_TMUX_TARGET -> @2).
tmux_badge_set "🟢" || fail "badge for clear-current test should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "precondition: window should be badged"
tmux_badge_clear_current || fail "clear-current should succeed"
[[ "$(window_name)" == "zsh" ]] || fail "clear-current should restore the current window (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear-current should drop the badge state"
pass "clear-current clears the caller's window"

# --- clear-current is a no-op without a badge ---
: > "$log_file"
tmux_badge_clear_current || fail "clear-current without a badge should still succeed"
grep -q "rename-window" "$log_file" && fail "clear-current without a badge should not rename"
pass "clear-current no-op without a badge"

# --- the badge-clear-current subcommand clears from a subprocess ---
# Exactly what the UserPromptSubmit hook runs: a fresh `bash tmux.sh
# badge-clear-current`, inheriting TMUX/TMUX_PANE from the pane it fired in.
tmux_badge_set "🟢" || fail "badge for clear-current subcommand test should succeed"
bash "$ROOT_DIR/lib/code-notify/utils/tmux.sh" badge-clear-current
[[ "$(window_name)" == "zsh" ]] || fail "badge-clear-current subcommand should clear the window (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "badge-clear-current subcommand should drop the badge state"
pass "badge-clear-current subcommand clears the window"

# --- badge-set suppresses the focus hook on request ---
# CODE_NOTIFY_TMUX_FOCUS_HOOK=false suppresses arming even for glance badges;
# the badge itself is still set.
: > "$log_file"
CODE_NOTIFY_TMUX_FOCUS_HOOK=false tmux_badge_set "🟢" || fail "suppressed-hook badge should still succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "badge should still be set when the focus hook is suppressed"
grep -q "set-hook -g session-window-changed" "$log_file" && fail "suppressed focus hook must not be armed"
tmux_badge_clear "@2"
pass "badge-set suppresses the focus hook on request"

# --- glance badge records its clear mode ---
tmux_badge_set "🟢" || fail "glance badge should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "glance" ]] \
    || fail "default badge should record clear mode glance"
tmux_badge_clear "@2"
[[ ! -f "$state_dir/@2.@code_notify_clear_mode" ]] \
    || fail "clear should unset the clear-mode option"
pass "glance badge records its clear mode"

# --- engage badge records its mode and arms no focus hook ---
: > "$log_file"
tmux_badge_set "🟢" engage || fail "engage badge should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "engage badge should still rename the window"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
    || fail "engage badge should record clear mode engage"
grep -q "set-hook -g session-window-changed" "$log_file" \
    && fail "engage badge must not arm the glance-clear focus hook"
pass "engage badge records mode without arming the focus hook"

# --- sweep skips engage badges (and doesn't count them for the hook) ---
# The engage badge from above is visible, but only its owner's prompt-submit
# may clear it: the sweep must leave it badged. With no glance badge anywhere,
# the sweep must also retire the focus hook — an engage badge alone must not
# keep it alive.
export FAKE_TMUX_WINDOWS=$'@2|1|engage|zsh'
: > "$log_file"
tmux_badge_sweep
[[ "$(window_name)" == "🟢 zsh" ]] \
    || fail "sweep must not clear a visible engage badge (got: $(window_name))"
[[ -f "$state_dir/@2.@code_notify_orig_name" ]] \
    || fail "sweep must not drop an engage badge's state"
grep -qF "set-hook -gu session-window-changed[8471]" "$log_file" \
    || fail "an engage badge alone must not keep the focus hook alive"
export FAKE_TMUX_WINDOWS=""
pass "sweep skips engage badges"

# --- clear-current clears an engage badge ---
# The owning agent's prompt-submit signal is the one path that clears an
# engage badge.
tmux_badge_clear_current || fail "clear-current on an engage badge should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "clear-current should clear an engage badge (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_clear_mode" ]] \
    || fail "clear-current should drop the engage badge's clear-mode option"
pass "clear-current clears an engage badge"

# --- running-start badges even the visible window with the static icon ---
export FAKE_TMUX_BADGE_INFO='@2|on|1|zsh'   # visible: event badges skip it, running must not
tmux_running_start || fail "running-start should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] || fail "running-start should set the static icon on a visible window (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "running" ]] \
    || fail "running marker should record clear mode running"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "running-start should store the start epoch"
pass "running-start sets the static icon and epoch"

# --- sweep leaves a fresh running marker alone ---
export FAKE_TMUX_WINDOWS="@2|1|running|zsh"
tmux_badge_sweep
[[ "$(window_name)" == "🌕 zsh" ]] || fail "sweep must not clear a fresh running marker (got: $(window_name))"
[[ -f "$state_dir/@2.@code_notify_running" ]] || fail "sweep must keep a fresh running epoch"
export FAKE_TMUX_WINDOWS=""
pass "sweep skips a fresh running marker"

# --- running-stop clears the marker and epoch ---
tmux_running_stop || fail "running-stop should succeed"
[[ "$(window_name)" == "zsh" ]] || fail "running-stop should restore the name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] || fail "running-stop should drop the epoch"
[[ ! -f "$state_dir/@2.@code_notify_clear_mode" ]] || fail "running-stop should drop the badge state"
pass "running-stop clears marker and epoch"

# --- exiting an agent clears its running marker instead of waiting for TTL ---
# Hooks record the owning agent PID in real use. An impossible PID simulates a
# user quitting Codex/Claude (or closing the terminal) without a Stop hook.
tmux_running_start || fail "running-start before agent-exit cleanup should succeed"
printf '%s' "999999" > "$state_dir/@2.@code_notify_agent_pid"
tmux_agent_exit_sweep || fail "agent-exit sweep should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "agent exit should restore the static running badge (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "agent exit should drop the running epoch"
[[ ! -f "$state_dir/@2.@code_notify_agent_pid" ]] \
    || fail "agent exit should drop the tracked process"
pass "agent exit clears the static running marker promptly"

# --- an exited agent also clears a pending completion/input badge ---
# Back to a hidden window: an engage badge skips a visible one (visible_action
# defaults to skip), which would make every badge_set below a silent no-op.
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
tmux_badge_set "🟢" engage || fail "badge before agent-exit cleanup should succeed"
printf '%s' "999999" > "$state_dir/@2.@code_notify_agent_pid"
tmux_agent_exit_sweep || fail "badge agent-exit sweep should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "agent exit should restore an event badge (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] \
    || fail "agent exit should drop pending badge state"
pass "agent exit clears a pending event badge promptly"

# --- agent exit cleanup is scoped to the owning window ---
# A tmux server can have several Codex/Claude/agy panes. A dead process in one
# must not clear an unrelated live agent's marker or badge.
tmux_badge_set "🟢" engage || fail "dead-window badge setup should succeed"
printf '%s' "999999" > "$state_dir/@2.@code_notify_agent_pid"
printf '%s' "code" > "$state_dir/@5.@code_notify_orig_name"
printf '%s' "off" > "$state_dir/@5.@code_notify_autorename"
printf '%s' "🌕 code" > "$state_dir/@5.@code_notify_badged_name"
printf '%s' "running" > "$state_dir/@5.@code_notify_clear_mode"
printf '%s' "🌕 code" > "$state_dir/@5.window_name"
printf '%s' "$(date +%s)" > "$state_dir/@5.@code_notify_running"
printf '%s' "$$" > "$state_dir/@5.@code_notify_agent_pid"
tmux_agent_exit_sweep || fail "multi-window agent-exit sweep should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "dead agent cleanup should restore only its own window (got: $(window_name))"
[[ "$(cat "$state_dir/@5.window_name")" == "🌕 code" ]] \
    || fail "live agent window must retain its running marker"
[[ -f "$state_dir/@5.@code_notify_agent_pid" ]] \
    || fail "live agent window must retain its tracked process"
rm -f "$state_dir/@5.@code_notify_orig_name" "$state_dir/@5.@code_notify_autorename" \
    "$state_dir/@5.@code_notify_badged_name" "$state_dir/@5.@code_notify_clear_mode" \
    "$state_dir/@5.@code_notify_running" "$state_dir/@5.@code_notify_agent_pid" "$state_dir/@5.window_name"
pass "agent exit cleanup is scoped to the owning window"

# --- the sweep leaves untracked windows alone ---
# Real tmux lists every window, with an empty pid field when the option is
# unset — e.g. an agy StopFinal badge, whose disowned watcher can never
# resolve an agent pid. Those badges live by glance/engage/TTL rules and must
# survive the exit sweep, even while a tracked agent keeps it re-arming.
tmux_badge_set "🟢" engage || fail "untracked badge setup should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "precondition: window should carry the untracked badge"
rm -f "$state_dir/@2.@code_notify_agent_pid"                # never tracked
printf '%s' "$$" > "$state_dir/@5.@code_notify_agent_pid"   # live tracked window elsewhere
tmux_agent_exit_sweep || fail "untracked-window sweep should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] \
    || fail "sweep must not clear an untracked window's badge (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
    || fail "sweep must not drop an untracked window's badge state"
rm -f "$state_dir/@5.@code_notify_agent_pid"
tmux_badge_clear "@2"
pass "agent-exit sweep leaves untracked windows alone"

# --- an input pause resumes only on a later lifecycle signal ---
tmux_running_start || fail "running-start before input pause should succeed"
tmux_running_pause_for_input || fail "input pause should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "input pause should remove the running epoch"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "input pause should retain a resume marker"
[[ "$(window_name)" == "zsh" ]] \
    || fail "input pause should restore the static running icon (got: $(window_name))"
tmux_running_resume_after_input || fail "input resume should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "input resume should restore the running epoch"
[[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "input resume should consume the resume marker"
[[ "$(window_name)" == "🌕 zsh" ]] \
    || fail "input resume should restore the static running icon (got: $(window_name))"
tmux_running_stop || fail "cleanup after input resume should succeed"
pass "input pause resumes the running indicator once"

# --- a watched input pause defers its snapshot and schedules the poll ---
# No hook fires when the user answers an approval dialog, so a "watch" pause
# records its pane and parks a short run-shell timer on the server. It must not
# checksum synchronously: the hook's own transient status line is still on
# screen and its disappearance is not a user answer. The payload carries the
# poll settings AND the active
# running-indicator configuration — the timer's fresh process would otherwise
# resume with default icon/spinner/TTL, flipping per-session overrides.
rm -f "$state_dir/.@code_notify_resume_poll_scheduled"
printf '%s' "approval dialog" > "$state_dir/%3.pane_content"
TMUX_RUNNING_ICON="🚀"   # per-session override; must survive into the payload
tmux_running_start || fail "running-start before the poll-schedule test should succeed"
: > "$log_file"
tmux_running_pause_for_input watch || fail "watched pause for the poll-schedule test should succeed"
grep -q "^run-shell -b -d 2 " "$log_file" \
    || fail "a watched input pause should schedule the 2s resume poll"
[[ -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
    || fail "the pending poll should be recorded in @code_notify_resume_poll_scheduled"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3" ]] \
    || fail "a watched pause should defer its dialog snapshot"
grep "^run-shell -b -d 2 " "$log_file" | grep -q "CODE_NOTIFY_TMUX_RUNNING_ICON='🚀'" \
    || fail "the poll payload should carry the running-indicator configuration"
pass "watched pause defers the dialog snapshot and schedules the poll"

# --- the first poll baselines the settled dialog without resuming ---
# Run the timer payload exactly as tmux would (/bin/sh -c, no TMUX_PANE).
# The notification hook's status UI may have disappeared since the pause; the
# first poll must absorb that change as its baseline, not call it an answer.
payload=$(sed -n 's/^run-shell -b -d 2 \(.*\)$/\1/p' "$log_file" | head -n 1)
[[ -n "$payload" ]] || fail "the poll payload should be extractable from the run-shell call"
pending=$(cat "$state_dir/@2.@code_notify_resume_pending")
printf '%s' "approval dialog after hook status cleared" > "$state_dir/%3.pane_content"
printf '%s' "$((pending + 5))" > "$state_dir/@2.window_activity"
: > "$log_file"
env -u TMUX_PANE /bin/sh -c "$payload" || fail "the poll payload should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the first poll must not restore the running epoch"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a quiet window should keep its pause marker"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3 "* ]] \
    || fail "the first poll should save the settled dialog baseline"
grep -q "^run-shell -b -d 2 " "$log_file" \
    || fail "the poll should reschedule while a pause marker remains"
pass "first poll baselines hook UI changes without resuming"

# --- a glance (activity without content change) must not resume ---
# Visiting the waiting window delivers a focus event and the TUI repaints the
# same dialog: #{window_activity} advances but the snapshot still matches, so
# the poll must keep waiting instead of showing a running agent.
rm -f "$state_dir/.@code_notify_resume_poll_scheduled"
printf '%s' "$((pending + 5))" > "$state_dir/@2.window_activity"   # focus repaint
: > "$log_file"
env -u TMUX_PANE /bin/sh -c "$payload" || fail "the glance poll payload should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a glance must not restore the running epoch"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a glanced-at window should keep its pause marker"
grep -q "^run-shell -b -d 2 " "$log_file" \
    || fail "the poll should keep watching after a glance"
pass "glance advances activity but does not resume"

# --- a vanished pane must not read as a content change ---
# capture-pane fails on a closed split; cksum of that empty pipe would be a
# valid-looking checksum that differs from the snapshot, resuming a window
# whose agent is gone (nothing would ever correct it — the agent fires no
# more hooks). The failure must propagate and keep the window waiting.
rm -f "$state_dir/%3.pane_content"   # the watched split was closed
tmux_resume_poll_sweep || fail "poll sweep with a vanished pane should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a vanished pane must not restore the running epoch"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a vanished pane should keep its pause marker for the hooks"
printf '%s' "approval dialog" > "$state_dir/%3.pane_content"
pass "vanished pane keeps waiting instead of resuming"

# --- a pane moved to another window must not resume the recorded one ---
# break-pane keeps the pane id alive under a different window; its content
# says nothing about the recorded window's dialog.
export FAKE_TMUX_PANE_WINDOW='@9'
printf '%s' "content of some other window" > "$state_dir/%3.pane_content"
tmux_resume_poll_sweep || fail "poll sweep with a moved pane should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a moved pane's content must not resume the recorded window"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a moved pane should keep the recorded window's pause marker"
unset FAKE_TMUX_PANE_WINDOW
printf '%s' "approval dialog" > "$state_dir/%3.pane_content"
pass "moved pane keeps the recorded window waiting"

# --- a content change resumes the indicator with the configured icon ---
rm -f "$state_dir/.@code_notify_resume_poll_scheduled"
printf '%s' "tool output streaming" > "$state_dir/%3.pane_content"   # user answered
: > "$log_file"
env -u TMUX_PANE /bin/sh -c "$payload" || fail "the resuming poll payload should run cleanly"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "a changed dialog snapshot should restore the running epoch"
[[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "the poll resume should consume the pause marker"
[[ ! -f "$state_dir/@2.@code_notify_pause_fp" ]] \
    || fail "the poll resume should consume the dialog snapshot"
[[ "$(window_name)" == "🚀 zsh" ]] \
    || fail "the poll resume should use the configured running icon (got: $(window_name))"
grep -q "^run-shell -b -d 2 " "$log_file" \
    && fail "the poll must not reschedule once no pause marker remains"
rm -f "$state_dir/@2.window_activity" "$state_dir/%3.pane_content"
tmux_running_stop || fail "cleanup after the poll resume should succeed"
TMUX_RUNNING_ICON="🌕"
pass "content change resumes the indicator via the poll"

# --- an unanswered request past the poll TTL stops the chain ---
# A dialog left open must not tick a 2s timer forever, and — even while a
# fresher pause elsewhere keeps the chain alive — an expired pause must not
# resume on late activity: the TTL gate comes before the content check. The
# marker stays for the lifecycle hooks.
printf '%s' "1000" > "$state_dir/@2.@code_notify_resume_pending"    # ancient pause
printf '%s' "%3 123 4" > "$state_dir/@2.@code_notify_pause_fp"      # snapshot mismatch
printf '%s' "$(date +%s)" > "$state_dir/@2.window_activity"         # late activity
printf '%s' "changed content" > "$state_dir/%3.pane_content"
rm -f "$state_dir/.@code_notify_resume_poll_scheduled"
: > "$log_file"
tmux_resume_poll_sweep || fail "poll sweep on an expired pause should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "an expired pause must not resume even on a changed snapshot"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "an expired pause should keep its marker for the lifecycle hooks"
grep -q "^run-shell -b -d 2 " "$log_file" \
    && fail "the poll must not reschedule past TMUX_RESUME_POLL_TTL"
rm -f "$state_dir/@2.@code_notify_resume_pending" "$state_dir/@2.@code_notify_pause_fp" \
    "$state_dir/@2.window_activity" "$state_dir/%3.pane_content"
pass "unanswered request past the poll TTL stops the chain"

# --- an idle-style pause must not arm the activity poll ---
# An idle reminder pauses without "watch": no turn is running, so pane
# activity after it (clicking the toast, typing the next prompt) must not
# light the spinner. UserPromptSubmit is its resume signal.
rm -f "$state_dir/.@code_notify_resume_poll_scheduled"
tmux_running_start || fail "running-start before the idle-pause test should succeed"
: > "$log_file"
tmux_running_pause_for_input || fail "idle-style pause should succeed"
grep -q "^run-shell -b -d 2 " "$log_file" \
    && fail "a pause without watch must not schedule the resume poll"
[[ ! -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
    || fail "a pause without watch must not record a pending poll"
[[ ! -f "$state_dir/@2.@code_notify_pause_fp" ]] \
    || fail "a pause without watch must not leave a dialog snapshot"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "an idle-style pause should still retain the resume marker"
rm -f "$state_dir/@2.@code_notify_resume_pending" \
    "$state_dir/@2.@code_notify_pause_fp" \
    "$state_dir/.@code_notify_resume_poll_scheduled"
pass "idle-style pause keeps the marker without arming the poll"

# --- an uncapturable pane keeps only the deferred watch marker ---
# Capture is deliberately deferred until the hook UI settles. If that first
# capture fails, the poll keeps the pane-only marker and retries; it must never
# manufacture a checksum or resume the window from missing content.
rm -f "$state_dir/.@code_notify_resume_poll_scheduled" "$state_dir/%3.pane_content"
tmux_running_start || fail "running-start before the no-snapshot test should succeed"
: > "$log_file"
tmux_running_pause_for_input watch || fail "watched pause without a capturable pane should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3" ]] \
    || fail "a deferred watch should initially retain only its pane id"
tmux_resume_poll_sweep || fail "the first uncapturable-pane poll should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3" ]] \
    || fail "a failed baseline capture must not create a dialog checksum"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a failed baseline capture must not resume the running indicator"
grep -q "^run-shell -b -d 2 " "$log_file" \
    || fail "an uncapturable pane should remain watched for a later capture"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "the pause marker should still be retained for the hooks"
rm -f "$state_dir/@2.@code_notify_resume_pending" \
    "$state_dir/@2.@code_notify_pause_fp" \
    "$state_dir/.@code_notify_resume_poll_scheduled"
pass "uncapturable pane remains paused while the baseline is retried"

# --- codex running marker arms the settle watch; claude's does not ---
# Codex ends /review without any turn-end hook, so its running marker gets a
# pane-settle watch (TMUX_SETTLE_AGENTS). Claude has real Stop hooks and must
# not be watched — its idle screen is static even mid-approval.
CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
    || fail "codex prompt-submit should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_settle_pane" 2>/dev/null)" == "%3" ]] \
    || fail "codex prompt-submit should arm the settle watch on its pane"
tmux_running_stop || fail "running-stop after codex settle arm should succeed"
[[ ! -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "running-stop should disarm the settle watch"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit should succeed"
[[ ! -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "claude prompt-submit must not arm the settle watch"
tmux_running_stop || fail "running-stop after claude prompt should succeed"
pass "settle watch arms for codex only"

# The settle path calls the notifier synchronously after removing the running
# state. Keep this unit section isolated from desktop delivery; the macOS
# end-to-end section below exercises the real notifier and badge transition.
settle_notify_log="$test_dir/settle-notify.log"
cat > "$fake_bin/settle-notifier-stub" <<EOF
#!/bin/bash
running=0
[[ -f "$state_dir/@2.@code_notify_running" ]] && running=1
printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "\$TMUX_PANE" "\$1" "\$2" "\$3" \
    "\${CODE_NOTIFY_TMUX_IDLE_AGENTS:-}" \
    "\$(cat "$state_dir/@2.window_name" 2>/dev/null)" "\$running" \
    >> "$settle_notify_log"
EOF
chmod +x "$fake_bin/settle-notifier-stub"

# --- a settled codex pane takes the running marker down and completes ---
# Tick 1 stores the snapshot; a changed pane resets the countdown; once the
# pane holds still past the threshold (forced to 0 here), the sweep retires
# marker, restores the window name, and synthesizes the missing completion —
# the /review-without-stop case.
printf '%s' "review: analyzing diff" > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
    || fail "codex prompt-submit for the settle flow should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] || fail "precondition: running icon should be up"
tmux_agent_exit_sweep || fail "first settle tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the first tick only snapshots; it must not stop the marker"
[[ -f "$state_dir/@2.@code_notify_settle_fp" ]] \
    || fail "the first tick should store the pane snapshot"
printf '%s' "review: writing findings" > "$state_dir/%3.pane_content"
tmux_agent_exit_sweep || fail "second settle tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a still-painting pane must keep the running marker"
: > "$settle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" \
    TMUX_SETTLE_SECONDS=0 tmux_agent_exit_sweep \
    || fail "settling tick should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a settled pane should retire the running marker"
[[ "$(window_name)" == "zsh" ]] \
    || fail "the settle stop should restore the window name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "the settle stop should disarm the watch"
[[ "$(cat "$settle_notify_log")" == "%3|stop|codex|"*"|zsh|0" ]] \
    || fail "settle should invoke stop only after clearing the running rendering (got: $(cat "$settle_notify_log"))"
rm -f "$state_dir/%3.pane_content"
pass "settled codex pane retires running state before synthetic completion"

# --- scheduled settle completion preserves idle configuration ---
# The synthetic stop runs inside the timer's fresh process and arms its idle
# watch there, so the originating session's allowlist must ride the payload.
settle_handoff_round() {
    # $1: env value for TMUX_IDLE_AGENTS ("" = default). Arms a codex settle
    # watch, seeds it as already settled, then runs the scheduled payload
    # exactly as tmux would (fresh /bin/sh, no TMUX_PANE).
    printf '%s' "review output" > "$state_dir/%3.pane_content"
    rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
    : > "$log_file"
    : > "$settle_notify_log"
    if [[ -n "$1" ]]; then
        CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" \
            TMUX_IDLE_AGENTS="$1" CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
            || return 1
    else
        CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" \
            CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit || return 1
    fi
    printf '%s' "$(printf '%s\n' "review output" | cksum)" \
        > "$state_dir/@2.@code_notify_settle_fp"
    printf '%s' "1000" > "$state_dir/@2.@code_notify_settle_since"
    payload=$(sed -n 's/^run-shell -b -d 5 \(.*\)$/\1/p' "$log_file" | head -n 1)
    [[ -n "$payload" ]] || return 1
    env -u TMUX_PANE /bin/sh -c "$payload"
}
settle_handoff_round "" || fail "default-allowlist handoff round should run cleanly"
[[ "$(cat "$settle_notify_log")" == *"|codex|antigravity|zsh|0" ]] \
    || fail "scheduled completion should inherit the default idle allowlist (got: $(cat "$settle_notify_log"))"
rm -f "$state_dir/%3.pane_content" \
    "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
settle_handoff_round "antigravity" || fail "override-allowlist handoff round should run cleanly"
[[ "$payload" == *"CODE_NOTIFY_TMUX_IDLE_AGENTS='antigravity'"* ]] \
    || fail "the scheduled payload should carry the session's allowlist"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the scheduled settle stop should still retire the running marker"
[[ "$(cat "$settle_notify_log")" == *"|antigravity|zsh|0" ]] \
    || fail "synthetic completion should receive the overridden idle allowlist (got: $(cat "$settle_notify_log"))"
rm -f "$state_dir/%3.pane_content" "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
printf '%s' "zsh" > "$state_dir/@2.window_name"
pass "scheduled synthetic completion preserves idle configuration"

# --- idle watch: arm gating (agent list, alert types, pane capture) ---
# Codex/Antigravity never send an idle reminder after a completion, so their
# stop events arm a post-completion idle watch; Claude nudges natively and
# must not be watched. The nudge is an alert type (idle_prompt), so the arm
# also honours the notify-types file, and an uncapturable pane never arms.
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX || fail "idle arm for codex should succeed"
iw="$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)"
[[ "$iw" == "%3 "* ]] || fail "idle arm should record the watched pane (got: $iw)"
[[ "$iw" == *" codex projX" ]] \
    || fail "idle arm should record agent and project (got: $iw)"
rm -f "$state_dir/@2.@code_notify_idle_watch"
tmux_idle_watch_arm_current antigravity projX || fail "idle arm for antigravity should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)" == *" antigravity projX" ]] \
    || fail "antigravity (agy StopFinal path) should arm the idle watch too"
rm -f "$state_dir/@2.@code_notify_idle_watch"
tmux_idle_watch_arm_current claude projX || fail "idle arm for claude should no-op cleanly"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "claude must not get an idle watch (it has a native idle_prompt)"
mkdir -p "$HOME/.claude/notifications"
printf '%s' "permission_prompt" > "$HOME/.claude/notifications/notify-types"
tmux_idle_watch_arm_current codex projX \
    || fail "idle arm with idle_prompt disabled should no-op cleanly"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "a disabled idle_prompt alert type must not arm the idle watch"
rm -f "$HOME/.claude/notifications/notify-types" "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX \
    || fail "idle arm without a capturable pane should no-op cleanly"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "an uncapturable pane must not arm the idle watch"
pass "idle watch arms for hook-less agents only, gated on alert type and capture"

# --- idle watch: sweep lifecycle (settling / young / fired / changed / vanished) ---
# The stub notifier logs its identity-bearing invocation; delivery is
# detached, so assertions on the log wait briefly.
idle_notify_log="$test_dir/idle-notify.log"
cat > "$fake_bin/notifier-stub" <<EOF
#!/bin/bash
printf '%s|%s|%s|%s|' "\$TMUX_PANE" "\$1" "\$2" "\$3" >> "$idle_notify_log"
cat >> "$idle_notify_log"
printf '\n' >> "$idle_notify_log"
EOF
chmod +x "$fake_bin/notifier-stub"
wait_for_idle_log() {
    local i
    for i in $(seq 1 50); do
        [[ -s "$idle_notify_log" ]] && return 0
        sleep 0.1
    done
    return 1
}
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX || fail "idle arm for the sweep tests should succeed"
# Codex repaints after Stop returns. The first changed snapshot must become the
# new settling baseline instead of cancelling the reminder.
printf '%s' "codex final frame" > "$state_dir/%3.pane_content"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "first settling sweep should succeed"
iw="$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)"
[[ "$iw" == *" settling codex projX" ]] \
    || fail "Codex's final repaint should refresh the settling baseline (got: $iw)"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "second settling sweep should succeed"
iw="$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)"
[[ "$iw" == *" stable codex projX" ]] \
    || fail "two matching snapshots should stabilize the idle watch (got: $iw)"
pass "codex final repaint settles instead of cancelling the idle watch"

rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "sweep with a young idle watch should succeed"
[[ -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "a young idle watch must survive the tick"
[[ ! -s "$idle_notify_log" ]] || fail "a young idle watch must not notify"
grep -q "^run-shell -b -d 5 " "$log_file" \
    || fail "an armed idle watch should keep the sweep chain alive"
pass "young idle watch keeps the sweep ticking without notifying"

# Stillness past the threshold fires the synthetic idle_prompt once, with the
# watched pane in TMUX_PANE and the recorded identity in argv, then consumes
# the watch and lets the chain die.
idle_fp="$(printf '%s\n' "codex final frame" | cksum)"
printf '%s' "%3 1000 $idle_fp stable codex projX" > "$state_dir/@2.@code_notify_idle_watch"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "idle-firing sweep should succeed"
wait_for_idle_log || fail "stillness past the threshold should invoke the notifier"
[[ "$(cat "$idle_notify_log")" == '%3|notification|codex|projX|{"type":"idle_prompt"}' ]] \
    || fail "the synthetic nudge should carry pane, event, agent, project and payload (got: $(cat "$idle_notify_log"))"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "the fired idle watch should be consumed"
grep -q "^run-shell -b -d 5 " "$log_file" \
    && fail "the sweep chain must die once nothing is watched"
pass "stillness past the threshold fires the synthetic idle nudge once"

# A content change means the user is already there: disarm silently, even
# past the threshold.
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX || fail "re-arm for the change test should succeed"
idle_fp="$(printf '%s\n' "turn finished, waiting" | cksum)"
printf '%s' "%3 1000 $idle_fp stable codex projX" > "$state_dir/@2.@code_notify_idle_watch"
printf '%s' "user typed something" > "$state_dir/%3.pane_content"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "sweep after a content change should succeed"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "changed content should disarm the idle watch"
sleep 0.3
[[ ! -s "$idle_notify_log" ]] || fail "changed content must not notify"
grep -q "^run-shell -b -d 5 " "$log_file" \
    && fail "a disarmed idle watch must not keep the chain alive"
pass "content change disarms the idle watch without notifying"

# A vanished pane disarms silently too — after a completed turn there is no
# recovery path worth keeping open, and cksum-of-empty must not read as a
# stable pane.
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX || fail "re-arm for the vanish test should succeed"
printf '%s' "%3 1000 $idle_fp stable codex projX" > "$state_dir/@2.@code_notify_idle_watch"
rm -f "$state_dir/%3.pane_content"   # the watched split was closed
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "sweep with a vanished idle pane should succeed"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "a vanished pane should disarm the idle watch"
sleep 0.3
[[ ! -s "$idle_notify_log" ]] || fail "a vanished pane must not notify"
pass "vanished pane disarms the idle watch silently"

# --- acknowledgment paths cancel the pending nudge ---
# Clearing the badge (glance visit, cleanup) and the click-to-clear command
# both mean the user attended the window.
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_badge_set "🟢" glance || fail "badge for the acknowledgment test should succeed"
tmux_idle_watch_arm_current codex projX || fail "idle arm for the acknowledgment test should succeed"
tmux_badge_clear "@2" || fail "badge clear should succeed"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "clearing the badge should disarm the idle watch"
clear_cmd=$(tmux_badge_build_clear_command) || fail "clear command should build"
[[ "$clear_cmd" == *"@code_notify_idle_watch"* ]] \
    || fail "the click-to-clear command should disarm the idle watch"
rm -f "$state_dir/%3.pane_content"
pass "badge clear and notification click cancel the pending idle nudge"

# --- ordinary tool lifecycle signals must not start a spinner ---
: > "$log_file"
tmux_running_resume_after_input || fail "resume without an input pause should succeed"
grep -q "rename-window" "$log_file" \
    && fail "resume without a pending marker must not create a running badge"
pass "resume hook ignores ordinary tool activity"

# --- running-stop leaves an event badge that replaced the marker ---
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
tmux_running_start || fail "running-start before event badge should succeed"
tmux_badge_set "🟢" engage || fail "event badge should succeed"
tmux_running_stop || fail "running-stop after event badge should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "running-stop must not clear an event badge (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] || fail "running-stop should still drop the epoch"
tmux_badge_clear "@2"
pass "running-stop leaves a replacing event badge alone"

# --- stale running marker is retired by the sweep ---
tmux_running_start || fail "running-start for staleness test should succeed"
printf '%s' "1000" > "$state_dir/@2.@code_notify_running"   # ancient epoch
export FAKE_TMUX_WINDOWS="@2|1000|running|zsh"              # id|since|mode for the running sweep
tmux_running_sweep_stale
[[ "$(window_name)" == "zsh" ]] || fail "stale sweep should restore the name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] || fail "stale sweep should drop the epoch"
export FAKE_TMUX_WINDOWS=""
pass "stale running marker is retired"

# --- a fresh running marker schedules a one-shot stale sweep on the server ---
# Every other sweep call site needs later activity on the server; the run-shell
# timer is what retires a dead run's marker when none ever comes.
rm -f "$state_dir/.@code_notify_sweep_scheduled"   # earlier cases armed one
: > "$log_file"
tmux_running_start || fail "running-start for the schedule test should succeed"
grep -q "^run-shell -b -d " "$log_file" \
    || fail "a fresh running marker should schedule a delayed stale sweep"
delay=$(sed -n 's/^run-shell -b -d \([0-9][0-9]*\) .*/\1/p' "$log_file" | head -n 1)
[[ "${delay:-0}" -ge $((TMUX_RUNNING_TTL - 60)) ]] \
    || fail "the timer should fire only after the marker can expire (got delay: $delay)"
[[ -f "$state_dir/.@code_notify_sweep_scheduled" ]] \
    || fail "the pending timer should be recorded in @code_notify_sweep_scheduled"
pass "fresh running marker schedules a delayed stale sweep"

# --- a pending timer is not stacked by further sweeps ---
sched_count=$(grep -c "^run-shell -b -d " "$log_file")
tmux_running_sweep_stale
[[ "$(grep -c "^run-shell -b -d " "$log_file")" == "$sched_count" ]] \
    || fail "a pending timer must not be re-armed by another sweep"
pass "pending timer is not stacked"

# --- the scheduled payload clears the flag and retires a stale marker ---
# Extract the run-shell payload exactly as tmux would execute it after the
# delay: /bin/sh -c, no TMUX_PANE. The marker is aged past the TTL first, so
# the timer's sweep must restore the window and drop the epoch and the flag.
payload=$(sed -n 's/^run-shell -b -d [0-9][0-9]* \(.*\)$/\1/p' "$log_file" | head -n 1)
[[ -n "$payload" ]] || fail "the timer payload should be extractable from the run-shell call"
printf '%s' "1000" > "$state_dir/@2.@code_notify_running"   # went stale before firing
env -u TMUX_PANE /bin/sh -c "$payload" || fail "the timer payload should run cleanly"
[[ ! -f "$state_dir/.@code_notify_sweep_scheduled" ]] \
    || fail "the timer payload should clear the pending flag before sweeping"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the timer's sweep should retire the stale marker"
[[ "$(window_name)" == "zsh" ]] \
    || fail "the timer's sweep should restore the window name (got: $(window_name))"
pass "scheduled sweep retires a stale marker end-to-end"

# --- the timer's sweep re-schedules while fresher markers remain ---
tmux_running_start || fail "running-start for the re-schedule test should succeed"
rm -f "$state_dir/.@code_notify_sweep_scheduled"   # pretend the timer just fired
: > "$log_file"
tmux_running_sweep_stale
grep -q "^run-shell -b -d " "$log_file" \
    || fail "a sweep that leaves fresh markers behind should re-arm the timer"
tmux_running_stop || fail "cleanup running-stop should succeed"
pass "sweep re-schedules while fresh markers remain"

# --- running disabled via badge kill switch ---
: > "$log_file"
CODE_NOTIFY_TMUX_BADGE=false tmux_running_start || fail "disabled running-start should still exit 0"
grep -q "rename-window" "$log_file" && fail "disabled running-start must not rename"
pass "running-start honours the badge kill switch"

# --- spinner: arm injects the snippet, saves state, disarm restores ---
printf '%s' "THEME-FMT" > "$state_dir/.window-status-format"
printf '%s' "THEME-CUR" > "$state_dir/.window-status-current-format"
printf '%s' "10" > "$state_dir/.status-interval"
tmux_spinner_arm || fail "spinner arm should succeed"
snip="$(cat "$state_dir/.@code_notify_spinner_snip")"
[[ "$snip" == *"🌑"* && "$snip" == *"🌘"* ]] || fail "spinner snippet should contain the moon frames"
[[ "$snip" == *'#{T:@code_notify_clock}'* ]] || fail "spinner snippet should be wall-clock driven"
[[ "$snip" == *'@code_notify_running'* ]] || fail "spinner snippet should gate on the running option"
[[ "$(cat "$state_dir/.window-status-format")" == "$snip"THEME-FMT ]] \
    || fail "arm should prepend the snippet to window-status-format"
[[ "$(cat "$state_dir/.window-status-current-format")" == "$snip"THEME-CUR ]] \
    || fail "arm should prepend the snippet to window-status-current-format"
[[ "$(cat "$state_dir/.status-interval")" == "1" ]] || fail "arm should lower status-interval to 1"
[[ "$(cat "$state_dir/.@code_notify_saved_interval")" == "10" ]] || fail "arm should save the user's interval"
tmux_spinner_arm || fail "second arm should be a no-op"
[[ "$(cat "$state_dir/.window-status-format")" == "$snip"THEME-FMT ]] \
    || fail "arm must be idempotent (snippet stacked)"
tmux_spinner_disarm || fail "spinner disarm should succeed"
[[ "$(cat "$state_dir/.window-status-format")" == "THEME-FMT" ]] \
    || fail "disarm should restore window-status-format (got: $(cat "$state_dir/.window-status-format"))"
[[ "$(cat "$state_dir/.window-status-current-format")" == "THEME-CUR" ]] \
    || fail "disarm should restore window-status-current-format"
[[ "$(cat "$state_dir/.status-interval")" == "10" ]] || fail "disarm should restore status-interval"
[[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] || fail "disarm should drop the saved snippet"
pass "spinner arm/disarm round-trips the status-line state"

# --- spinner: #I themes render the moon after the window number ---
printf '%s' "#[fg=grey] #I #{window_name} " > "$state_dir/.window-status-format"
printf '%s' "#[fg=green] #I #{window_name} " > "$state_dir/.window-status-current-format"
tmux_spinner_arm || fail "spinner arm for #I placement should succeed"
snip="$(cat "$state_dir/.@code_notify_spinner_snip")"
[[ "$(cat "$state_dir/.window-status-format")" == "#[fg=grey] #I $snip#{window_name} " ]] \
    || fail "spinner should follow #I in window-status-format"
[[ "$(cat "$state_dir/.window-status-current-format")" == "#[fg=green] #I $snip#{window_name} " ]] \
    || fail "spinner should follow #I in window-status-current-format"
tmux_spinner_disarm || fail "spinner disarm after #I placement should succeed"
[[ "$(cat "$state_dir/.window-status-format")" == "#[fg=grey] #I #{window_name} " ]] \
    || fail "spinner disarm should restore an inline #I format"
pass "spinner follows the window number"

# --- spinner: user-replaced format is left alone on disarm ---
tmux_spinner_arm || fail "arm for replaced-format test should succeed"
printf '%s' "USER-NEW-FMT" > "$state_dir/.window-status-format"   # user replaced it wholesale
tmux_spinner_disarm || fail "disarm after user replacement should succeed"
[[ "$(cat "$state_dir/.window-status-format")" == "USER-NEW-FMT" ]] \
    || fail "disarm must not touch a format the user replaced (got: $(cat "$state_dir/.window-status-format"))"
pass "spinner disarm keeps a user-replaced format"

# --- spinner: user-changed interval is left alone on disarm ---
printf '%s' "10" > "$state_dir/.status-interval"
tmux_spinner_arm || fail "arm for the interval-guard test should succeed"
printf '%s' "5" > "$state_dir/.status-interval"   # user changed it while armed
tmux_spinner_disarm || fail "disarm after an interval change should succeed"
[[ "$(cat "$state_dir/.status-interval")" == "5" ]] \
    || fail "disarm must not clobber a user-changed status-interval (got: $(cat "$state_dir/.status-interval"))"
[[ ! -f "$state_dir/.@code_notify_saved_interval" ]] \
    || fail "disarm should still drop the saved interval"
pass "spinner disarm keeps a user-changed interval"

# --- spinner: session-local intervals are lowered and restored ---
# The global status-interval set does not reach a session with a local value;
# its spinner would tick at the slower local rate.
export FAKE_TMUX_SESSIONS='$1'
printf '%s' "10" > "$state_dir/.status-interval"
printf '%s' "9" > "$state_dir"/'$1.status-interval'
tmux_spinner_arm || fail "arm for the session-interval test should succeed"
[[ "$(cat "$state_dir"/'$1.status-interval')" == "1" ]] \
    || fail "arm should lower a session-local interval to 1"
[[ "$(cat "$state_dir"/'$1.@code_notify_saved_interval')" == "9" ]] \
    || fail "arm should save the session-local interval"
tmux_spinner_disarm || fail "disarm for the session-interval test should succeed"
[[ "$(cat "$state_dir"/'$1.status-interval')" == "9" ]] \
    || fail "disarm should restore the session-local interval (got: $(cat "$state_dir"/'$1.status-interval'))"
[[ ! -f "$state_dir"/'$1.@code_notify_saved_interval' ]] \
    || fail "disarm should drop the session bookkeeping"
pass "session-local intervals are lowered and restored"

# --- spinner: sessions appearing after arm are synced, user changes win ---
tmux_spinner_arm || fail "arm for the late-session test should succeed"
export FAKE_TMUX_SESSIONS=$'$1\n$4'
printf '%s' "7" > "$state_dir"/'$4.status-interval'   # created after arm
tmux_spinner_arm || fail "re-arm should succeed"
[[ "$(cat "$state_dir"/'$4.status-interval')" == "1" ]] \
    || fail "an already-armed spinner should still sync a late session's interval"
[[ "$(cat "$state_dir"/'$4.@code_notify_saved_interval')" == "7" ]] \
    || fail "the late session's interval should be saved"
printf '%s' "3" > "$state_dir"/'$1.status-interval'   # user changed it while armed
tmux_spinner_arm || fail "re-arm after a user change should succeed"
[[ "$(cat "$state_dir"/'$1.status-interval')" == "3" ]] \
    || fail "a session the user re-raised while armed must not be re-lowered"
tmux_spinner_disarm || fail "disarm for the late-session test should succeed"
[[ "$(cat "$state_dir"/'$1.status-interval')" == "3" ]] \
    || fail "disarm must keep a session interval the user changed while armed"
[[ "$(cat "$state_dir"/'$4.status-interval')" == "7" ]] \
    || fail "disarm should restore the late session's interval"
rm -f "$state_dir"/'$1.status-interval' "$state_dir"/'$4.status-interval'
export FAKE_TMUX_SESSIONS=""
pass "late sessions are synced and user changes win"

# --- spinner mode: running-start arms without renaming ---
rm -f "$state_dir/.window-status-format" "$state_dir/.window-status-current-format"
printf '%s' "10" > "$state_dir/.status-interval"
mkdir -p "$HOME/.claude/notifications"
touch "$HOME/.claude/notifications/tmux-spinner-enabled"
: > "$log_file"
tmux_running_start || fail "spinner-mode running-start should succeed"
grep -q "rename-window" "$log_file" && fail "spinner mode must not rename the window"
[[ -f "$state_dir/.@code_notify_spinner_snip" ]] || fail "spinner mode should arm the status-line spinner"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "spinner mode should still store the start epoch"
pass "spinner-mode running-start arms without renaming"

# --- spinner mode: running-start clears a waiting event badge ---
tmux_running_stop || fail "spinner-mode setup stop should succeed"
tmux_badge_set "💬" engage || fail "spinner-mode waiting badge setup should succeed"
[[ "$(window_name)" == "💬 zsh" ]] \
    || fail "precondition: window should carry the waiting badge"
tmux_running_start || fail "spinner-mode resume from waiting badge should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "spinner-mode resume should clear the waiting badge (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_clear_mode" ]] \
    || fail "spinner-mode resume should remove the waiting badge state"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "spinner-mode resume should retain the running epoch"
pass "spinner-mode running-start clears a waiting event badge"

# --- spinner mode: running-stop disarms once nothing is running ---
export FAKE_TMUX_WINDOWS="@2|"   # no running epoch anywhere after the stop
tmux_running_stop || fail "spinner-mode running-stop should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] || fail "spinner-mode stop should drop the epoch"
[[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "last running-stop should disarm the spinner"
[[ "$(cat "$state_dir/.status-interval")" == "10" ]] || fail "last running-stop should restore status-interval"
export FAKE_TMUX_WINDOWS=""
pass "spinner-mode running-stop disarms when idle"

# --- spinner mode: an exited agent disarms without waiting for TTL ---
tmux_running_start || fail "spinner-mode running-start before agent exit should succeed"
printf '%s' "999999" > "$state_dir/@2.@code_notify_agent_pid"
tmux_agent_exit_sweep || fail "spinner-mode agent-exit sweep should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "agent exit should drop the spinner running epoch"
[[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "agent exit should disarm the spinner immediately"
pass "agent exit clears the spinner promptly"

# --- spinner mode: a settled review removes the spinner before completion ---
printf '%s' "review complete in spinner mode" > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
    || fail "spinner-mode codex review start should succeed"
[[ -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "spinner-mode review should arm the spinner"
spinner_review_fp="$(printf '%s\n' "review complete in spinner mode" | cksum)"
printf '%s' "$spinner_review_fp" > "$state_dir/@2.@code_notify_settle_fp"
printf '%s' "1000" > "$state_dir/@2.@code_notify_settle_since"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$settle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" \
    TMUX_SETTLE_SECONDS=0 tmux_agent_exit_sweep \
    || fail "spinner-mode settled review sweep should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "settled spinner-mode review should drop the running epoch"
[[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "settled spinner-mode review should disarm the spinner"
[[ "$(cat "$settle_notify_log")" == "%3|stop|codex|"*"|zsh|0" ]] \
    || fail "spinner should be visually inactive before synthetic completion (got: $(cat "$settle_notify_log"))"
rm -f "$state_dir/%3.pane_content"
pass "settled review removes the spinner before synthetic completion"

# --- spinner mode: env var override forces it off ---
: > "$log_file"
CODE_NOTIFY_TMUX_SPINNER=false tmux_running_start || fail "env-forced static running-start should succeed"
grep -q "rename-window" "$log_file" || fail "CODE_NOTIFY_TMUX_SPINNER=false must fall back to the static icon"
tmux_running_stop
rm -f "$HOME/.claude/notifications/tmux-spinner-enabled"
pass "spinner env override forces static mode"

# --- spinner off mid-run: running windows fall back to the static icon ---
# `cn spinner off` disarms the snippet while agents are still working; each
# window with a fresh running epoch must be re-badged with the static icon or
# it would carry no indicator at all until its run ends.
touch "$HOME/.claude/notifications/tmux-spinner-enabled"
: > "$log_file"
tmux_running_start || fail "running-start for the spinner-off test should succeed"
grep -q "rename-window" "$log_file" && fail "precondition: spinner mode must not rename"
[[ -f "$state_dir/.@code_notify_spinner_snip" ]] || fail "precondition: spinner should be armed"
rm -f "$HOME/.claude/notifications/tmux-spinner-enabled"   # what `cn spinner off` does
tmux_spinner_disarm || fail "disarm for the spinner-off test should succeed"
tmux_running_apply_static_badges || fail "apply-static-badges should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] \
    || fail "spinner off must re-badge running windows with the static icon (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "running" ]] \
    || fail "the fallback badge should be a running-mode marker"
pass "spinner off falls back to the static icon on running windows"

# --- the static fallback skips stale epochs ---
tmux_running_stop || fail "cleanup running-stop should succeed"
printf '%s' "1000" > "$state_dir/@2.@code_notify_running"   # dead run, long stale
: > "$log_file"
tmux_running_apply_static_badges || fail "apply-static-badges on a stale epoch should still succeed"
grep -q "rename-window" "$log_file" && fail "a stale running epoch must not get a fallback badge"
rm -f "$state_dir/@2.@code_notify_running"
pass "static fallback skips stale epochs"

# --- spinner on mid-run: static running badges convert to the snippet ---
# `cn spinner on` while an agent works: the static 🌕 rename and the newly
# armed snippet render from the same epoch, so the rename must come off or
# the window shows both indicators at once.
tmux_running_start || fail "running-start for the spinner-on test should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] || fail "precondition: window should carry the static running icon"
tmux_running_convert_static_badges_to_spinner || fail "convert-to-spinner should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "spinner on must drop the static running rename (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "the running epoch must survive the conversion — the spinner keys on it"
[[ -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "conversion should arm the spinner when a fresh marker exists"
tmux_spinner_disarm || fail "cleanup disarm should succeed"
tmux_running_stop || fail "cleanup running-stop after conversion should succeed"
pass "spinner on converts static running badges to the snippet"

# --- the conversion leaves event badges and idle windows alone ---
printf '%s' "1000" > "$state_dir/@2.@code_notify_running"   # stale epoch only
tmux_badge_set "👋" engage || fail "event badge for the conversion test should succeed"
tmux_running_convert_static_badges_to_spinner || fail "convert on stale/idle should succeed"
[[ "$(window_name)" == "👋 zsh" ]] \
    || fail "conversion must not touch an event badge (got: $(window_name))"
[[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "conversion must not arm the spinner when no fresh marker exists"
tmux_badge_clear "@2"
rm -f "$state_dir/@2.@code_notify_running"
pass "conversion skips event badges and stale epochs"

# --- prompt-submit fast path: engage badge swaps to the running icon ---
# The synchronous prompt path must not clear-restore-then-rebadge (two
# renames) or run a server-wide sweep: one capture, one rename, timer armed.
tmux_badge_set "🟢" engage || fail "engage badge for the prompt-submit test should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "precondition: window should be engage-badged"
: > "$log_file"
tmux_prompt_submit || fail "prompt-submit should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] \
    || fail "prompt-submit should swap the event badge for the running icon (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "running" ]] \
    || fail "prompt-submit should leave a running-mode marker"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "prompt-submit should store the running epoch"
[[ "$(grep -c "rename-window" "$log_file")" == "1" ]] \
    || fail "the badge swap should cost exactly one rename"
grep -q "^list-windows" "$log_file" && fail "prompt-submit must not run a server-wide sweep"
tmux_running_stop || fail "cleanup running-stop should succeed"
pass "prompt-submit swaps the badge in one rename, no sweep"

# --- prompt-submit in spinner mode: clears the badge, arms, no re-badge ---
touch "$HOME/.claude/notifications/tmux-spinner-enabled"
tmux_badge_set "🟢" engage || fail "engage badge for the spinner prompt-submit test should succeed"
: > "$log_file"
tmux_prompt_submit || fail "spinner-mode prompt-submit should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "spinner-mode prompt-submit should clear the event badge (got: $(window_name))"
[[ -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "spinner-mode prompt-submit should arm the spinner"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "spinner-mode prompt-submit should store the epoch"
[[ "$(grep -c "rename-window" "$log_file")" == "1" ]] \
    || fail "spinner mode should rename only to restore the cleared badge"
tmux_running_stop || fail "cleanup running-stop should succeed"
rm -f "$HOME/.claude/notifications/tmux-spinner-enabled"
pass "spinner-mode prompt-submit clears the badge and arms the spinner"

# --- prompt-submit with the running indicator disabled still engage-clears ---
tmux_badge_set "🟢" engage || fail "engage badge for the disabled prompt-submit test should succeed"
CODE_NOTIFY_TMUX_RUNNING=false tmux_prompt_submit || fail "disabled prompt-submit should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "prompt-submit must clear the badge even with the running indicator disabled (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "disabled prompt-submit must not store an epoch"
pass "disabled prompt-submit still engage-clears"

# Antigravity uses its first PreToolUse as the engage signal. That reaches the
# generic running-start path rather than tmux_prompt_submit, and must still
# clear a waiting badge when the running indicator itself is disabled.
tmux_badge_set "🟢" engage || fail "engage badge for the disabled running-start test should succeed"
CODE_NOTIFY_TMUX_RUNNING=false tmux_running_start || fail "disabled running-start should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "running-start must engage-clear with the indicator disabled (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "disabled running-start must not store an epoch"
pass "disabled running-start still engage-clears"

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
tmux_badge_set "🟢" || fail "badge for manual-rename clear-command test should succeed"
printf '%s' "work" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "clear command should run cleanly after a manual rename"
[[ "$(window_name)" == "work" ]] || fail "clear command must not clobber a manual rename (got: $(window_name))"
grep -q "rename-window" "$log_file" && fail "clear command after a manual rename should not rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear command should still drop the badge state"
pass "generated clear command keeps manual rename"

# --- generated clear command keeps a rename that ends in the original name ---
tmux_badge_set "🟢" || fail "badge for suffix-colliding clear-command test should succeed"
printf '%s' "api zsh" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "clear command should run cleanly after a suffix-colliding rename"
[[ "$(window_name)" == "api zsh" ]] || fail "clear command must not clobber a rename ending in the original name (got: $(window_name))"
grep -q "rename-window" "$log_file" && fail "clear command after a suffix-colliding rename should not rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear command should still drop the badge state after a suffix-colliding rename"
pass "generated clear command keeps suffix-colliding manual rename"

# --- notifier.sh end-to-end wiring (macOS only) ---
# Claude is an engage-clear agent: a stop event badges the origin window with 🟢
# and passes -focus, but does NOT attach a click-to-clear command (clicking is a
# glance). The badge clears on the next UserPromptSubmit instead.
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
    : > "$log_file"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh should exit cleanly"

    [[ "$(window_name)" == "🟢 zsh" ]] || fail "notifier should badge the origin window with the stop icon (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
        || fail "Claude badge should record clear mode engage"
    grep -qx -- "-focus" "$tn_log" || fail "notifier should pass -focus"
    grep -q -- "@code_notify_orig_name" "$tn_log" \
        && fail "Claude notification must not carry a click-to-clear command (clears on prompt-submit)"
    grep -q "set-hook -g session-window-changed" "$log_file" \
        && fail "Claude badge-set must not arm the glance-clear focus hook"
    pass "notifier end-to-end: Claude badges without glance-clearing"

    # UserPromptSubmit: the user handed this window work, so the event badge
    # clears and the running marker (agent now working) replaces it.
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" UserPromptSubmit claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh UserPromptSubmit should exit cleanly"
    [[ "$(window_name)" == "🌕 zsh" ]] \
        || fail "UserPromptSubmit should clear the event badge and set the running icon (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "running" ]] \
        || fail "UserPromptSubmit should leave a running-mode marker"
    [[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
        || fail "UserPromptSubmit should store the running epoch"
    pass "notifier end-to-end: UserPromptSubmit swaps event badge for running marker"

    # The next stop event takes the running marker off before badging 🟢.
    rm -f "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh stop after running should exit cleanly"
    [[ "$(window_name)" == "🟢 zsh" ]] \
        || fail "stop should replace the running icon with the event badge (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_running" ]] \
        || fail "stop should drop the running epoch"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
        || fail "the replacing event badge should be engage-clear"
    # Reset for the codex cases below, which assume a clean window.
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" UserPromptSubmit claude testproj > /dev/null 2>&1 || true
    rm -f "$state_dir/@2.@code_notify_running" "$state_dir/@2.@code_notify_clear_mode" \
        "$state_dir/@2.@code_notify_orig_name" "$state_dir/@2.@code_notify_autorename" \
        "$state_dir/@2.@code_notify_badged_name" 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: stop replaces the running marker with the event badge"

    # Responding to an in-turn request does not emit UserPromptSubmit. The
    # notifier must therefore keep a pause marker from the notification and
    # let its PostToolUse hook restore the running indicator.
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh input request should exit cleanly"
    [[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "input request should retain a tmux resume marker"
    [[ ! -f "$state_dir/@2.@code_notify_running" ]] \
        || fail "input request should stop the running indicator"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" PostToolUse claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh PostToolUse resume should exit cleanly"
    [[ "$(window_name)" == "🌕 zsh" ]] \
        || fail "PostToolUse should restore the running icon after input (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "PostToolUse should consume the input pause marker"
    rm -f "$state_dir/@2.@code_notify_running" "$state_dir/@2.@code_notify_clear_mode" \
        "$state_dir/@2.@code_notify_orig_name" "$state_dir/@2.@code_notify_autorename" \
        "$state_dir/@2.@code_notify_badged_name" 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: input response restores the running marker"

    # A permission request is an answerable mid-turn dialog: on top of the
    # pause marker it must arm the activity resume poll. The untyped
    # notification above (an idle-style pause) must not have — no turn is
    # running there, and toast-click/typing activity would light the spinner.
    [[ ! -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
        || fail "a generic notification must not arm the activity poll"
    printf '%s' "permission dialog" > "$state_dir/%3.pane_content"
    : > "$log_file"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        <<< '{"message": "Claude needs your permission to use Bash"}' \
        || fail "notifier.sh permission request should exit cleanly"
    [[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "permission request should retain a tmux resume marker"
    [[ "$(cat "$state_dir/@2.@code_notify_pause_fp" 2>/dev/null)" == "%3" ]] \
        || fail "permission request should defer its dialog snapshot"
    grep -q "^run-shell -b -d 2 " "$log_file" \
        || fail "permission request should schedule the 2s resume poll"
    [[ -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
        || fail "permission request should record the pending poll"
    rm -f "$state_dir/@2.@code_notify_resume_pending" "$state_dir/@2.@code_notify_running" \
        "$state_dir/@2.@code_notify_clear_mode" "$state_dir/@2.@code_notify_orig_name" \
        "$state_dir/@2.@code_notify_autorename" "$state_dir/@2.@code_notify_badged_name" \
        "$state_dir/@2.@code_notify_pause_fp" "$state_dir/%3.pane_content" \
        "$state_dir/.@code_notify_resume_poll_scheduled" 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: permission request arms the activity poll"

    # Codex reaches the notifier via its hooks.json as `notifier.sh stop codex`,
    # so RAW_ARG1 is "stop" and only TOOL_NAME is "codex". With no
    # UserPromptSubmit hook registered (no ~/.codex/hooks.json here) it must
    # glance-clear: badge set, focus hook armed, and the click-to-clear command
    # attached. Guards the RAW_ARG1-vs-TOOL_NAME bug and the engage-clear gate's
    # fallback — a badge must never be left without a clear path.
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    : > "$log_file"
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop codex testproj > /dev/null 2>&1 \
        || fail "notifier.sh stop codex should exit cleanly"
    [[ "$(window_name)" == "🟢 zsh" ]] \
        || fail "codex stop (hooks.json path) should badge the window (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "glance" ]] \
        || fail "codex badge without a prompt hook should record clear mode glance"
    grep -q "set-hook -g session-window-changed" "$log_file" \
        || fail "codex (glance-clear) badge-set must arm the focus hook"
    grep -q -- "@code_notify_orig_name" "$tn_log" \
        || fail "codex notification should carry the click-to-clear command"
    pass "notifier end-to-end: codex without a prompt hook keeps glance-clearing"

    # A user's own unrelated UserPromptSubmit hook must not switch Codex to
    # engage mode: it won't clear our badge, so glance-clearing has to stay on
    # or the badge would be stuck. Only the managed Code-Notify command counts.
    mkdir -p "$HOME/.codex"
    cat > "$HOME/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "/usr/local/bin/my-own-hook.sh"}]}
    ]
  }
}
EOF
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    : > "$log_file"
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop codex testproj > /dev/null 2>&1 \
        || fail "notifier.sh stop codex (unrelated prompt hook) should exit cleanly"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "glance" ]] \
        || fail "an unrelated UserPromptSubmit hook must not switch codex to engage mode"
    grep -q "set-hook -g session-window-changed" "$log_file" \
        || fail "codex with only an unrelated prompt hook must still arm the focus hook"
    pass "notifier end-to-end: unrelated prompt hook keeps codex glance-clearing"

    # With the UserPromptSubmit hook registered in Codex's hooks.json (what
    # `cn on codex` now installs), Codex is an engage-clear agent like Claude:
    # engage-mode badge, no focus hook, no click-to-clear — the badge clears on
    # the next prompt instead.
    cat > "$HOME/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "notify.sh UserPromptSubmit codex"}]}
    ]
  }
}
EOF
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    : > "$log_file"
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop codex testproj > /dev/null 2>&1 \
        || fail "notifier.sh stop codex (prompt hook installed) should exit cleanly"
    [[ "$(window_name)" == "🟢 zsh" ]] \
        || fail "codex stop should still badge the window with the prompt hook installed (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
        || fail "codex badge with the prompt hook should record clear mode engage"
    grep -q "set-hook -g session-window-changed" "$log_file" \
        && fail "codex (engage-clear) badge-set must not arm the focus hook"
    grep -q -- "@code_notify_orig_name" "$tn_log" \
        && fail "codex (engage-clear) notification must not carry a click-to-clear command"
    pass "notifier end-to-end: codex with the prompt hook engage-clears"

    # And the Codex UserPromptSubmit event itself clears the badge, leaving
    # the running marker in its place (codex is now working on the prompt).
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" UserPromptSubmit codex testproj > /dev/null 2>&1 \
        || fail "notifier.sh UserPromptSubmit codex should exit cleanly"
    [[ "$(window_name)" == "🌕 zsh" ]] \
        || fail "codex UserPromptSubmit should swap the event badge for the running icon (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "running" ]] \
        || fail "codex UserPromptSubmit should leave a running-mode marker"
    pass "notifier end-to-end: codex UserPromptSubmit swaps badge for running marker"

    # Codex /review emits no native stop. Once its pane settles, the sweep must
    # remove the running rendering first, synthesize the normal completion
    # (🟢 + toast), and arm the same idle watch as a native stop. If the
    # completed review remains untouched, that watch later replaces 🟢 with 🥱.
    printf '%s' "codex review findings" > "$state_dir/%3.pane_content"
    review_fp="$(printf '%s\n' "codex review findings" | cksum)"
    printf '%s' "$review_fp" > "$state_dir/@2.@code_notify_settle_fp"
    printf '%s' "1000" > "$state_dir/@2.@code_notify_settle_since"
    rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled" \
        "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        CODE_NOTIFY_NOTIFIER_PATH="$NOTIFIER" TMUX_SETTLE_SECONDS=0 \
        tmux_agent_exit_sweep \
        || fail "settled codex review should synthesize completion cleanly"
    [[ "$(window_name)" == "🟢 zsh" ]] \
        || fail "settled review should replace running with the completion badge (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_running" ]] \
        || fail "settled review completion should remove the running epoch"
    iw="$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)"
    [[ "$iw" == "%3 "*" codex "* ]] \
        || fail "settled review completion should arm the codex idle watch (got: $iw)"
    grep -q "Task Complete" "$tn_log" \
        || fail "settled review should deliver a task-complete notification"

    review_idle_fp="$(printf '%s\n' "codex review findings" | cksum)"
    printf '%s' "%3 1000 $review_idle_fp stable codex code-notify" \
        > "$state_dir/@2.@code_notify_idle_watch"
    rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
    : > "$tn_log"
    # Even a still-focused window is demonstrably untouched: the idle watch
    # held through the full threshold, so 🥱 must replace 🟢 rather than taking
    # the generic waiting-event visible-window skip.
    export FAKE_TMUX_BADGE_INFO='@2|on|1|zsh'
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_NOTIFIER_PATH="$NOTIFIER" tmux_agent_exit_sweep \
        || fail "settled review idle sweep should run cleanly"
    for _ in $(seq 1 100); do [[ "$(window_name)" == "🥱 zsh" ]] && break; sleep 0.1; done
    [[ "$(window_name)" == "🥱 zsh" ]] \
        || fail "review idle reminder should replace the completion badge (got: $(window_name))"
    for _ in $(seq 1 100); do grep -q "Input Required" "$tn_log" 2>/dev/null && break; sleep 0.1; done
    grep -q "Input Required" "$tn_log" \
        || fail "untouched review should deliver the later idle notification"
    export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
    rm -f "$HOME/.codex/hooks.json" "$state_dir"/* "$state_dir"/.@code_notify_* \
        "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: settled review completes, then idles"

    # A codex stop arms the post-completion idle watch (codex sends nothing
    # further once a turn ends), and a pane that then holds still past the
    # threshold delivers a synthetic idle_prompt back through the real
    # notifier: 🥱 badge on the origin window, toast via terminal-notifier.
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    printf '%s' "codex done, waiting" > "$state_dir/%3.pane_content"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop codex testproj > /dev/null 2>&1 \
        || fail "notifier.sh stop codex (idle-arm) should exit cleanly"
    iw="$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)"
    [[ "$iw" == "%3 "*" codex testproj" ]] \
        || fail "codex stop should arm the idle watch with agent and project (got: $iw)"
    # Backdate past the threshold and run the sweep exactly as the timer
    # would (fresh process, script dispatch); the synthetic notification
    # must come back through the real notifier.
    idle_fp="$(printf '%s\n' "codex done, waiting" | cksum)"
    printf '%s' "%3 1000 $idle_fp stable codex testproj" > "$state_dir/@2.@code_notify_idle_watch"
    rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$ROOT_DIR/lib/code-notify/utils/tmux.sh" agent-exit-sweep \
        || fail "idle sweep should run cleanly"
    for _ in $(seq 1 100); do [[ "$(window_name)" == "🥱 zsh" ]] && break; sleep 0.1; done
    [[ "$(window_name)" == "🥱 zsh" ]] \
        || fail "the synthetic idle nudge should badge the window (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
        || fail "the fired idle watch should be consumed"
    # The badge is written just before the toast is sent; wait for the
    # detached delivery separately.
    for _ in $(seq 1 100); do grep -q "Codex" "$tn_log" 2>/dev/null && break; sleep 0.1; done
    grep -q "Codex" "$tn_log" \
        || fail "the synthetic nudge should reach terminal-notifier"
    rm -f "$state_dir"/* "$state_dir"/.@code_notify_* \
        "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: codex stop arms the idle watch and the nudge fires"
fi

echo "All tmux badge tests passed"
