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
#   - clicking the notification (macOS only — the clear command rides the
#     notifier's click handler; Linux notify-send has no click hook)
#   - visiting the window (tmux_badge_sweep on the next notification, all
#     platforms)
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

tmux_badge_enabled() {
    [[ "${CODE_NOTIFY_TMUX_BADGE:-}" != "false" ]] && [[ ! -f "$TMUX_BADGE_DISABLED_FILE" ]]
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
    tmux_focus_available || return 0
    local window_id visible orig
    while IFS='|' read -r window_id visible orig; do
        [[ -n "$orig" ]] || continue
        [[ "$visible" == "1" ]] || continue
        tmux_badge_clear "$window_id"
    done < <(tmux list-windows -a -F \
        '#{window_id}|#{&&:#{window_active},#{session_attached}}|#{@code_notify_orig_name}' 2>/dev/null)
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
