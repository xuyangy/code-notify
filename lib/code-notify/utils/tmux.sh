#!/bin/bash

# tmux click-to-focus support for Code-Notify (macOS).
#
# When a notification originates from a process running inside a tmux pane
# (Claude Code, Codex, Gemini CLI hooks inherit TMUX/TMUX_PANE), these
# helpers build a shell command that jumps back to that exact pane when the
# user clicks the notification.
#
# The generated command runs from the notifier app's context (/bin/sh -c,
# minimal PATH, no attached tmux client), so it embeds the absolute tmux
# path, the server socket, and performs an explicit client lookup.

# Quote a value for safe single-quoted embedding in a shell command,
# escaping embedded single quotes: a'b -> 'a'\''b'
tmux_focus_shell_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

# Escape a string for embedding inside a tmux double-quoted command argument
# and return it wrapped in those double quotes. When a hook fires, tmux
# re-parses the stored command and, inside "...", processes \, " and $ itself —
# so shell-quoting the inner values (which only protects the innermost
# /bin/sh) is not enough: a ", \ or $ in an embedded path would break tmux's
# parse before /bin/sh ever sees the safely-quoted value. Escape backslashes
# first so the escapes we add are not re-escaped.
tmux_focus_cmd_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    printf '"%s"' "$value"
}

# Whether the current process is running inside a usable tmux pane.
tmux_focus_available() {
    [[ -n "${TMUX:-}" ]] && [[ -n "${TMUX_PANE:-}" ]] && command -v tmux &> /dev/null
}

# Print "session_id window_id pane_id" for the current pane.
# Uses stable tmux IDs ($N @N %N) that survive window renumbering.
tmux_focus_capture_target() {
    if ! tmux_focus_available; then
        return 1
    fi
    tmux display-message -p -t "$TMUX_PANE" '#{session_id} #{window_id} #{pane_id}' 2>/dev/null
}

# Build the command a notifier should run on click to focus the originating
# tmux session/window/pane. Takes an optional macOS bundle ID to activate.
# Prints nothing and returns 1 when not running inside tmux.
tmux_focus_build_command() {
    local bundle_id="${1:-}"
    local target session_id window_id pane_id tmux_bin socket_path

    target=$(tmux_focus_capture_target) || return 1
    read -r session_id window_id pane_id <<< "$target"

    # Only stable tmux IDs get embedded in the command; reject anything else.
    # Patterns live in variables so the \$ escape survives both bash and zsh.
    local session_re='^\$[0-9]+$' window_re='^@[0-9]+$' pane_re='^%[0-9]+$'
    if [[ ! "$session_id" =~ $session_re ]] ||
        [[ ! "$window_id" =~ $window_re ]] ||
        [[ ! "$pane_id" =~ $pane_re ]]; then
        return 1
    fi

    tmux_bin=$(command -v tmux)
    socket_path="${TMUX%%,*}"
    if [[ -z "$tmux_bin" ]] || [[ -z "$socket_path" ]]; then
        return 1
    fi

    local q_tmux q_socket q_session q_window q_pane q_bundle
    q_tmux=$(tmux_focus_shell_quote "$tmux_bin")
    q_socket=$(tmux_focus_shell_quote "$socket_path")
    q_session=$(tmux_focus_shell_quote "$session_id")
    q_window=$(tmux_focus_shell_quote "$window_id")
    q_pane=$(tmux_focus_shell_quote "$pane_id")

    # t() wraps tmux with the captured socket. The client lookup prefers the
    # most recently active client attached to the target session, then falls
    # back to the most recently active client overall and switches it over.
    # Append system dirs so head/sort/cut/open resolve even under the
    # notifier app's minimal PATH; appending keeps any existing PATH first.
    local cmd
    cmd="PATH=\"\${PATH:-}:/usr/bin:/bin\"; export PATH; "
    cmd+="t() { $q_tmux -S $q_socket \"\$@\" 2>/dev/null; }; "
    cmd+="t select-window -t $q_window; "
    cmd+="t select-pane -t $q_pane; "
    cmd+="c=\$(t list-clients -t $q_session -F \"#{client_activity} #{client_name}\" | sort -rn | head -n 1 | cut -d \" \" -f 2-); "
    cmd+="if [ -z \"\$c\" ]; then c=\$(t list-clients -F \"#{client_activity} #{client_name}\" | sort -rn | head -n 1 | cut -d \" \" -f 2-); fi; "
    cmd+="if [ -n \"\$c\" ]; then t switch-client -c \"\$c\" -t $q_session; fi"

    if [[ -n "$bundle_id" ]]; then
        q_bundle=$(tmux_focus_shell_quote "$bundle_id")
        cmd+="; open -b $q_bundle"
    fi

    printf '%s' "$cmd"
}

# --- tmux window badging ---------------------------------------------------
#
# When a notification fires, the originating tmux window's name gets the event
# icon prepended ("🎯 zsh"), so pending work is visible in the status line
# from anywhere in the session. Badge state lives in tmux window options
# (@code_notify_orig_name, @code_notify_autorename, @code_notify_badged_name)
# so it survives across hook processes and clears from any of them:
#   - visiting the window: a server hook (session-window-changed /
#     client-session-changed, installed lazily when the first badge is set)
#     sweeps the moment the window becomes active — whether the user switched
#     manually, clicked the notification, or used terminal-notifier -focusLast
#     (all run select-window / switch-client, which fire the hook)
#   - the next notification also sweeps, so badges converge even on a tmux
#     server that predates the hook install
#   - clicking the notification additionally rides the notifier's own click
#     handler (macOS -execute); Linux notify-send has no click hook
#
# The hook is retired the moment the last badge clears, so idle window
# switching (no badge pending — the common case) spawns nothing; the next badge
# re-arms it. Cost is therefore paid only while a badge is actually outstanding.
#
# rename-window implicitly turns off automatic-rename for the window, so the
# original setting is saved alongside the name and restored on clear.
#
# A manual rename while badged always wins: badge-set adopts the new name as
# the original, and clear keeps it (leaving automatic-rename off, as a manual
# rename implies) instead of restoring the stale saved name. Rename detection
# compares against the exact badged name saved at badge time
# (@code_notify_badged_name) — a suffix match alone would mistake a rename
# like "zsh" -> "api zsh" for a badged form of "zsh". Badges written by older
# versions lack the option, so a "<something> <original>" suffix match remains
# as the fallback for them only.

TMUX_BADGE_DISABLED_FILE="$HOME/.claude/notifications/tmux-badge-disabled"

# Absolute path to this library, so the tmux focus hook can re-invoke it as a
# script (bash <this> badge-sweep). Resolved at source time.
TMUX_BADGE_LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Fixed array index for our server hooks: reusing one index means re-setting on
# every badge overwrites in place (no stacking) while leaving the user's own
# hooks at other indices untouched. Overridable only for tests.
TMUX_BADGE_HOOK_INDEX="${CODE_NOTIFY_TMUX_HOOK_INDEX:-8471}"

tmux_badge_enabled() {
    [[ "${CODE_NOTIFY_TMUX_BADGE:-}" != "false" ]] && [[ ! -f "$TMUX_BADGE_DISABLED_FILE" ]]
}

# Install the server hook that clears a window's badge the instant it becomes
# active, so a manually switched-to (or focus-jumped) window sheds its badge
# without waiting for the next notification. Idempotent: the fixed index makes
# a repeat set overwrite rather than stack. session-window-changed covers
# switching windows within a session; client-session-changed covers switching
# between attached sessions. run-shell -b keeps tmux responsive.
#
# The hook embeds an absolute lib path that can outlive the install (uninstall
# while a badge is pending), and a dangling hook would then error on every
# window switch forever — the sweep that retires it can no longer run. So the
# hook guards itself: if the lib is gone, it unsets both hooks and exits
# silently. The tmux binary and socket are embedded for that self-retire
# because run-shell's environment guarantees neither PATH nor $TMUX. The whole
# run-shell argument is tmux-quoted (tmux_focus_cmd_quote) on top of the inner
# shell-quoting, so an embedded path containing ", \ or $ survives tmux's
# re-parse of the hook when it fires.
tmux_badge_install_focus_hook() {
    [[ -n "$TMUX_BADGE_LIB_PATH" ]] && [[ -f "$TMUX_BADGE_LIB_PATH" ]] || return 0
    local tmux_bin socket_path q_lib q_tmux q_socket idx retire inner hook_cmd
    tmux_bin=$(command -v tmux) || return 0
    socket_path="${TMUX%%,*}"
    [[ -n "$socket_path" ]] || return 0
    q_lib=$(tmux_focus_shell_quote "$TMUX_BADGE_LIB_PATH")
    q_tmux=$(tmux_focus_shell_quote "$tmux_bin")
    q_socket=$(tmux_focus_shell_quote "$socket_path")
    idx="$TMUX_BADGE_HOOK_INDEX"
    retire="$q_tmux -S $q_socket set-hook -gu 'session-window-changed[$idx]'; "
    retire+="$q_tmux -S $q_socket set-hook -gu 'client-session-changed[$idx]'"
    inner="if [ -f $q_lib ]; then bash $q_lib badge-sweep; else $retire; fi"
    hook_cmd="run-shell -b $(tmux_focus_cmd_quote "$inner")"
    tmux set-hook -g "session-window-changed[$idx]" "$hook_cmd" 2>/dev/null
    tmux set-hook -g "client-session-changed[$idx]" "$hook_cmd" 2>/dev/null
}

# Retire the focus hook. Called when the last badge clears, so idle window
# switching (the common case — no badge pending) costs nothing until the next
# badge re-arms it.
tmux_badge_uninstall_focus_hook() {
    tmux set-hook -gu "session-window-changed[$TMUX_BADGE_HOOK_INDEX]" 2>/dev/null
    tmux set-hook -gu "client-session-changed[$TMUX_BADGE_HOOK_INDEX]" 2>/dev/null
}

# Whether a live window name is a badged form of the saved original: exactly
# the name written at badge time, or — for badges from versions predating
# @code_notify_badged_name — anything ending in " <original>".
tmux_badge_name_is_badged() {
    local name="$1" orig_name="$2" badged_name="$3"
    if [[ -n "$badged_name" ]]; then
        [[ "$name" == "$badged_name" ]]
    else
        [[ "$name" == *" $orig_name" ]]
    fi
}

# Prepend an icon to the originating window's name. Idempotent: a repeat
# notification swaps the icon instead of stacking a second one. Windows the
# user is currently looking at (active window of an attached session) are
# skipped — the badge would be noise there.
tmux_badge_set() {
    local icon="$1"
    [[ -n "$icon" ]] || return 1
    tmux_badge_enabled || return 1
    tmux_focus_available || return 1

    # window_name goes last so embedded "|" cannot shift the other fields.
    local info window_id autorename visible name
    info=$(tmux display-message -p -t "$TMUX_PANE" \
        '#{window_id}|#{automatic-rename}|#{&&:#{window_active},#{session_attached}}|#{window_name}' 2>/dev/null) || return 1
    IFS='|' read -r window_id autorename visible name <<< "$info"

    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 1
    [[ "$visible" == "1" ]] && return 0

    local orig_name badged_name
    orig_name=$(tmux show-options -wqv -t "$window_id" @code_notify_orig_name 2>/dev/null)
    badged_name=$(tmux show-options -wqv -t "$window_id" @code_notify_badged_name 2>/dev/null)
    if [[ -z "$orig_name" ]]; then
        orig_name="$name"
        tmux set-option -w -t "$window_id" @code_notify_orig_name "$orig_name" 2>/dev/null || return 1
        tmux set-option -w -t "$window_id" @code_notify_autorename "${autorename:-off}" 2>/dev/null
    elif [[ "$name" != "$orig_name" ]] &&
        ! tmux_badge_name_is_badged "$name" "$orig_name" "$badged_name"; then
        # Badged, but the current name is neither the saved original nor the
        # badged form of it: the user renamed the window while it was badged.
        # Their name becomes the new original, and automatic-rename is pinned
        # off — restoring the pre-badge "on" would rename right past their
        # choice.
        orig_name="$name"
        tmux set-option -w -t "$window_id" @code_notify_orig_name "$orig_name" 2>/dev/null || return 1
        tmux set-option -w -t "$window_id" @code_notify_autorename off 2>/dev/null
    fi
    tmux rename-window -t "$window_id" "$icon $orig_name" 2>/dev/null || return 1
    tmux set-option -w -t "$window_id" @code_notify_badged_name "$icon $orig_name" 2>/dev/null
    # A badge now exists, so arm the focus hook that glance-clears it on the next
    # visit. Cheap and idempotent, so setting it per badge is fine. Suppressed
    # (CODE_NOTIFY_TMUX_FOCUS_HOOK=false) for agents that clear on prompt-submit
    # instead of on glance — see the notifier's badge-clearing model.
    [[ "${CODE_NOTIFY_TMUX_FOCUS_HOOK:-}" != "false" ]] && tmux_badge_install_focus_hook
    return 0
}

# Restore a badged window: original name back, automatic-rename re-enabled if
# it was on, badge options removed. No-op when the window carries no badge.
# If the user renamed the window while badged, their name wins: keep it (and
# leave automatic-rename off, as a manual rename implies) and only drop the
# badge state.
tmux_badge_clear() {
    local window_id="$1"
    local orig_name autorename badged_name current
    orig_name=$(tmux show-options -wqv -t "$window_id" @code_notify_orig_name 2>/dev/null)
    [[ -n "$orig_name" ]] || return 0
    autorename=$(tmux show-options -wqv -t "$window_id" @code_notify_autorename 2>/dev/null)
    badged_name=$(tmux show-options -wqv -t "$window_id" @code_notify_badged_name 2>/dev/null)
    current=$(tmux display-message -p -t "$window_id" '#{window_name}' 2>/dev/null)
    # Restore when the window still looks badged (the exact name written at
    # badge time) or already carries the original name; an empty result means
    # the name query failed, where restoring is the safer default.
    if [[ -z "$current" ]] || [[ "$current" == "$orig_name" ]] ||
        tmux_badge_name_is_badged "$current" "$orig_name" "$badged_name"; then
        tmux rename-window -t "$window_id" "$orig_name" 2>/dev/null
        if [[ "$autorename" == "on" ]]; then
            tmux set-option -w -t "$window_id" automatic-rename on 2>/dev/null
        fi
    fi
    tmux set-option -wu -t "$window_id" @code_notify_orig_name 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_autorename 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_badged_name 2>/dev/null
}

# Clear badges the user has implicitly acknowledged: any badged window that is
# now the active window of an attached session was visited without clicking
# the notification. Runs on every notification, so stale badges converge even
# though no daemon watches window focus. Intentionally not gated on
# tmux_badge_enabled — badges left over from before the feature was disabled
# should still be cleaned up.
tmux_badge_sweep() {
    # Only needs to be inside a tmux server with a tmux binary; unlike badge-set
    # it never touches the current pane, so it must not require TMUX_PANE (the
    # focus hook's run-shell context may not set it).
    { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 0
    local window_id visible orig remaining=0
    while IFS='|' read -r window_id visible orig; do
        [[ -n "$orig" ]] || continue
        if [[ "$visible" == "1" ]]; then
            tmux_badge_clear "$window_id"   # clear always drops the orig-name option
        else
            remaining=$((remaining + 1))    # badged but still hidden
        fi
    done < <(tmux list-windows -a -F \
        '#{window_id}|#{&&:#{window_active},#{session_attached}}|#{@code_notify_orig_name}' 2>/dev/null)
    # With no badge left anywhere, retire the focus hook so it stops spawning a
    # sweep on every window switch until the next badge re-arms it. Kept as an
    # explicit if (not `&& ...`) so the function still returns 0 when a badge
    # remains — a trailing false would trip callers running under `set -e`.
    if [[ "$remaining" -eq 0 ]]; then
        tmux_badge_uninstall_focus_hook
    fi
}

# Clear the badge on the window the caller is running in. This is the
# "engage-clear" path: an agent that emits a prompt-submit signal (Claude's
# UserPromptSubmit) runs this to drop the badge the moment the user hands the
# window more work — unlike the sweep/focus hook, which clear merely on glance.
# Pane-local (needs TMUX_PANE), so it resolves the current window and clears
# just that one.
tmux_badge_clear_current() {
    tmux_focus_available || return 0
    local target session_id window_id pane_id
    target=$(tmux_focus_capture_target) || return 0
    read -r session_id window_id pane_id <<< "$target"
    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 0
    tmux_badge_clear "$window_id"
}

# Build the command a notifier click handler runs to clear the badge on the
# originating window. Same execution context as tmux_focus_build_command
# (/bin/sh -c, minimal PATH, no attached client), so it embeds the absolute
# tmux path and socket. Reads the saved state at click time, so it is a no-op
# when the badge was already cleared (or never set).
tmux_badge_build_clear_command() {
    local target session_id window_id pane_id tmux_bin socket_path

    target=$(tmux_focus_capture_target) || return 1
    read -r session_id window_id pane_id <<< "$target"

    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 1

    tmux_bin=$(command -v tmux)
    socket_path="${TMUX%%,*}"
    if [[ -z "$tmux_bin" ]] || [[ -z "$socket_path" ]]; then
        return 1
    fi

    local q_tmux q_socket q_window
    q_tmux=$(tmux_focus_shell_quote "$tmux_bin")
    q_socket=$(tmux_focus_shell_quote "$socket_path")
    q_window=$(tmux_focus_shell_quote "$window_id")

    local cmd
    cmd="t() { $q_tmux -S $q_socket \"\$@\" 2>/dev/null; }; "
    cmd+="n=\$(t show-options -wqv -t $q_window @code_notify_orig_name); "
    cmd+="if [ -n \"\$n\" ]; then "
    # Same manual-rename guard as tmux_badge_clear: only restore when the
    # window still carries the exact name written at badge time, the original
    # name, or the name query failed (with the legacy suffix match when no
    # badged name was saved); a name the user chose while badged is kept, and
    # automatic-rename stays off.
    cmd+="w=\$(t display-message -p -t $q_window '#{window_name}'); "
    cmd+="b=\$(t show-options -wqv -t $q_window @code_notify_badged_name); "
    cmd+="r=0; "
    cmd+="if [ -z \"\$w\" ] || [ \"\$w\" = \"\$n\" ]; then r=1; "
    cmd+="elif [ -n \"\$b\" ]; then if [ \"\$w\" = \"\$b\" ]; then r=1; fi; "
    cmd+="else case \"\$w\" in *\" \$n\") r=1;; esac; fi; "
    cmd+="if [ \"\$r\" = 1 ]; then "
    cmd+="t rename-window -t $q_window \"\$n\"; "
    cmd+="if [ \"\$(t show-options -wqv -t $q_window @code_notify_autorename)\" = on ]; then "
    cmd+="t set-option -w -t $q_window automatic-rename on; fi; "
    cmd+="fi; "
    cmd+="t set-option -wu -t $q_window @code_notify_orig_name; "
    cmd+="t set-option -wu -t $q_window @code_notify_autorename; "
    cmd+="t set-option -wu -t $q_window @code_notify_badged_name; "
    cmd+="fi"

    printf '%s' "$cmd"
}

# When run as a script rather than sourced, dispatch the requested subcommand:
#   - badge-sweep: the tmux focus hook (`bash <this> badge-sweep`)
#   - badge-clear-current: the UserPromptSubmit hook clearing this window's badge
# Sourcing — the normal path, where BASH_SOURCE[0] differs from $0 — skips this.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        badge-sweep) tmux_badge_sweep ;;
        badge-clear-current) tmux_badge_clear_current ;;
    esac
fi
